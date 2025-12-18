module LlmToolkit
  class CallStreamingLlmJob < ApplicationJob
    queue_as :llm

    # Ensure only one job per conversation runs at a time
    # Additional jobs will wait in queue until the current one finishes
    # The key is the conversation_id (first argument)
    limits_concurrency to: 1, key: ->(conversation_id, *) { "conversation_#{conversation_id}" }

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
  end
end
