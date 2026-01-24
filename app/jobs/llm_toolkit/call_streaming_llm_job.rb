module LlmToolkit
  class CallStreamingLlmJob < ApplicationJob
    queue_as :llm

    # Ensure only one job per conversation runs at a time
    # Additional jobs will wait in queue until the current one finishes
    # The key is the conversation_id (first argument)
    # IMPORTANT: duration must be long enough for long-running LLM conversations with multiple tool calls
    # Default SolidQueue concurrency duration is only 3 minutes, which is too short
    limits_concurrency to: 1, key: ->(conversation_id, *) { "conversation_#{conversation_id}" }, duration: 60.minutes

    # Threshold percentage of context window to trigger continuation warning
    # At 90%, we inject a message telling the LLM to use continue_conversation
    CONTEXT_WARNING_THRESHOLD_PERCENT = 90
    
    # Default context window size if model doesn't specify one
    DEFAULT_CONTEXT_WINDOW = 200_000

    # Process streaming LLM requests asynchronously
    #
    # @param conversation_id [Integer] The ID of the conversation to process
    # @param llm_model_id [Integer] The ID of the LLM model to use
    # @param user_id [Integer] ID of the user making the request
    # @param tool_class_names [Array<String>] Names of tool classes to use (default: [])
    # @param broadcast_to [String, nil] Optional channel for broadcasting updates (default: nil)
    def perform(conversation_id, llm_model_id, user_id, tool_class_names = [], broadcast_to = nil)
      # Retrieve the conversation and model
      conversation = LlmToolkit::Conversation.find_by(id: conversation_id)
      original_llm_model = LlmToolkit::LlmModel.find_by(id: llm_model_id)

      return unless conversation && original_llm_model

      # Note: We no longer skip if conversation is "working" because the controller
      # now sets the status to "working" before enqueueing the job (for cancel button UX).
      # The limits_concurrency directive ensures only one job runs at a time per conversation.

      # Ensure tool_class_names is an array before mapping
      safe_tool_class_names = Array(tool_class_names)
      tool_classes = safe_tool_class_names.map { |class_name| class_name.constantize rescue nil }.compact

      # Log available tools for debugging
      tool_names = tool_classes.map { |tc| tc.respond_to?(:definition) ? tc.definition[:name] : tc.to_s.demodulize.underscore }
      Rails.logger.info("🔧 Available tools: #{tool_names.join(', ')}")
      
      # Check if LovelaceCuaAssistant is among the tools (hybrid mode)
      has_cua_assistant = tool_names.include?('lovelace_cua_assistant')
      if has_cua_assistant
        Rails.logger.info("🎯 Hybrid mode: LovelaceCuaAssistant available for browser automation when needed")
      end

      # Use the original model - the assistant will call LovelaceCuaAssistant tool when it needs browser automation
      final_llm_model = original_llm_model

      # 🚨 CHECK CONTEXT WINDOW LIMIT - Inject continuation warning if needed
      # This MUST happen BEFORE creating the assistant message so the LLM sees the warning
      inject_context_warning_if_needed(conversation, final_llm_model, tool_names, user_id)

      # Create initial status message
      initial_content = "🤔 Traitement de votre demande..."

      assistant_message = conversation.messages.create!(
        role: 'assistant',
        content: initial_content,
        user_id: user_id,
        llm_model: final_llm_model
      )

      # Set up Thread.current[:current_user_id] for tools that need it
      Thread.current[:current_user_id] = user_id

      Rails.logger.info("🔄 Using standard streaming service with model: #{final_llm_model.name}")
      Rails.logger.info("   Tools available: #{tool_names.length} tools")
      
      # Use the standard streaming service with all tools
      # The model will call LovelaceCuaAssistant when it needs browser automation
      service = LlmToolkit::CallStreamingLlmWithToolService.new(
        llm_model: final_llm_model,
        conversation: conversation,
        assistant_message: assistant_message,
        tool_classes: tool_classes,
        user_id: user_id,
        broadcast_to: broadcast_to
      )

      # Process the streaming LLM call
      response = service.call

      # If we have a finish_reason in the response and it's not already set on the message,
      # update the message with the finish_reason
      if response.is_a?(Hash) && response['finish_reason'].present? && assistant_message.finish_reason.blank?
        assistant_message.update(finish_reason: response['finish_reason'])
        Rails.logger.info("Updated message finish_reason from final response: #{response['finish_reason']}")
      end
    rescue => e
      Rails.logger.error("Error in CallStreamingLlmJob: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      
      # Update conversation status to resting on error
      conversation&.update(status: :resting)
      
      # Update the assistant message with error details
      if assistant_message
        assistant_message.update(
          content: "Error processing your streaming request: #{e.message}",
          is_error: true
        )
      end
    end
    
    private
    
    # Check if we're approaching the context window limit and inject a warning message
    # This forces the LLM to use continue_conversation before hitting the limit
    #
    # @param conversation [LlmToolkit::Conversation] The conversation
    # @param llm_model [LlmToolkit::LlmModel] The LLM model being used
    # @param tool_names [Array<String>] Available tool names
    # @param user_id [Integer] The user ID
    def inject_context_warning_if_needed(conversation, llm_model, tool_names, user_id)
      # Skip if continue_conversation tool is not available
      return unless tool_names.include?('continue_conversation')
      
      # Skip for sub-agent conversations (they manage their own context)
      return if conversation.respond_to?(:sub_agent?) && conversation.sub_agent?
      
      # Get the context window limit for this model (with fallback)
      max_context = llm_model.input_token_limit.presence || DEFAULT_CONTEXT_WINDOW
      
      # Calculate the warning threshold (90% by default)
      warning_threshold = (max_context * CONTEXT_WARNING_THRESHOLD_PERCENT / 100.0).to_i
      
      # Estimate current context size
      current_tokens = conversation.respond_to?(:estimate_current_context_size) ? 
                       conversation.estimate_current_context_size : 0
      
      # Check if we've exceeded the threshold
      return unless current_tokens >= warning_threshold
      
      usage_percent = ((current_tokens.to_f / max_context) * 100).round(1)
      
      Rails.logger.warn(
        "[CONTEXT LIMIT] Conversation #{conversation.id} at #{usage_percent}% " \
        "(#{current_tokens}/#{max_context} tokens). Injecting continuation warning."
      )
      
      # Inject a system message forcing the LLM to continue
      warning_message = build_context_warning_message(current_tokens, max_context, usage_percent)
      
      conversation.messages.create!(
        role: 'user',
        content: warning_message,
        user_id: user_id
      )
      
      Rails.logger.info("[CONTEXT LIMIT] Continuation warning injected for conversation #{conversation.id}")
    end
    
    # Build the warning message content
    #
    # @param current_tokens [Integer] Current estimated token count
    # @param max_context [Integer] Maximum context window size
    # @param usage_percent [Float] Current usage percentage
    # @return [String] The warning message
    def build_context_warning_message(current_tokens, max_context, usage_percent)
      <<~MESSAGE.strip
        🚨 **ATTENTION CRITIQUE : LIMITE DE CONTEXTE ATTEINTE (#{usage_percent}%)**

        Tu as utilisé ~#{format_number(current_tokens)} tokens sur #{format_number(max_context)} disponibles.

        **⚠️ ACTION OBLIGATOIRE :**
        Tu DOIS utiliser l'outil `continue_conversation` IMMÉDIATEMENT comme prochaine action.

        **Instructions :**
        1. NE réponds PAS à ce message avec du texte
        2. Utilise DIRECTEMENT l'outil `continue_conversation`
        3. Dans le summary, inclus :
           - Ce qui a été accompli jusqu'ici
           - L'état actuel du travail
           - Les fichiers/chemins importants
        4. Dans pending_tasks, décris précisément ce qu'il reste à faire
        5. Dans important_context, liste les variables, chemins, ou détails critiques

        **IMPORTANT :** Si tu ne continues pas maintenant, la conversation sera coupée et tout le contexte sera perdu.
      MESSAGE
    end
    
    # Format a number with spaces as thousands separator
    #
    # @param number [Integer] The number to format
    # @return [String] Formatted number
    def format_number(number)
      number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
    end
  end
end
