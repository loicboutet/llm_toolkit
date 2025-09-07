module LlmToolkit
  class CallStreamingLlmJob < ApplicationJob
    queue_as :llm

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

      # Ensure tool_class_names is an array before mapping
      safe_tool_class_names = Array(tool_class_names)
      tool_classes = safe_tool_class_names.map { |class_name| class_name.constantize rescue nil }.compact

      # 🎯 AUTO-SWITCH TO OPENAI FOR LOVELACE TOOLS OR USE DIRECT CUA
      # Check if we need to switch to an OpenAI model for Lovelace tools
      final_llm_model = LlmToolkit::LovelaceModelSwitcher.switch_model_if_needed(original_llm_model, tool_classes)
      
      # Check if we need to use direct OpenAI CUA (computer-use-preview)
      use_direct_cua = final_llm_model.respond_to?(:is_cua_model) && final_llm_model.is_cua_model

      # Log the switch if it happened
      if final_llm_model != original_llm_model
        Rails.logger.info("🔄 LOVELACE MODEL SWITCH:")
        Rails.logger.info("   Original model: #{original_llm_model.model_name}")
        Rails.logger.info("   Switched to: #{final_llm_model.model_name}")
        
        if use_direct_cua
          Rails.logger.info("   🎯 Using DIRECT OpenAI computer-use-preview for CUA")
        else
          Rails.logger.info("   🔄 Using OpenRouter OpenAI model for Lovelace")
        end
        
        # Log which tools triggered the switch
        lovelace_tools = tool_classes.select do |tool_class|
          tool_name = tool_class.definition[:name] rescue tool_class.to_s
          LlmToolkit::LovelaceModelSwitcher::LOVELACE_TOOLS.include?(tool_name)
        end
        lovelace_tool_names = lovelace_tools.map { |tc| tc.definition[:name] rescue tc.to_s }
        Rails.logger.info("   Lovelace tools: #{lovelace_tool_names.join(', ')}")
      end

      # Create the initial empty assistant message with the FINAL llm_model
      # For CUA, we still associate with original model but handle specially
      assistant_message = conversation.messages.create!(
        role: 'assistant',
        content: '',
        user_id: user_id,
        llm_model: use_direct_cua ? original_llm_model : final_llm_model # Keep original for CUA tracking
      )

      # Set up Thread.current[:current_user_id] for tools that need it
      Thread.current[:current_user_id] = user_id

      # Choose the appropriate service based on model type
      if use_direct_cua
        Rails.logger.info("🎯 Using OpenAI CUA Streaming Service for computer-use-preview")
        
        # Use the specialized CUA service that calls OpenAI directly
        service = LlmToolkit::OpenaiCuaStreamingService.new(
          conversation: conversation,
          assistant_message: assistant_message,
          tool_classes: tool_classes,
          user_id: user_id,
          broadcast_to: broadcast_to
        )
      else
        Rails.logger.info("🔄 Using standard streaming service with switched model: #{final_llm_model.model_name}")
        
        # Use the standard streaming service with the switched OpenAI model
        service = LlmToolkit::CallStreamingLlmWithToolService.new(
          llm_model: final_llm_model,
          conversation: conversation,
          assistant_message: assistant_message,
          tool_classes: tool_classes,
          user_id: user_id,
          broadcast_to: broadcast_to
        )
      end

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
        error_content = if use_direct_cua
          "❌ Erreur avec l'automatisation CUA OpenAI: #{e.message}"
        else
          "Error processing your streaming request: #{e.message}"
        end
        
        assistant_message.update(
          content: error_content,
          is_error: true
        )
      end
    end
  end
end