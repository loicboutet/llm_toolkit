module LlmToolkit
  class Conversation < ApplicationRecord
    # Include ActionView helpers needed for dom_id in broadcasts
    include ActionView::RecordIdentifier

    belongs_to :conversable, polymorphic: true, touch: true
    belongs_to :canceled_by, polymorphic: true, optional: true
    has_many :messages, class_name: 'LlmToolkit::Message', dependent: :destroy
    has_many :tool_uses, through: :messages, class_name: 'LlmToolkit::ToolUse'

    # Explicitly declare the attribute type for the enum
    attribute :agent_type, :integer
    attribute :status, :string

    # Now define the enums
    enum :agent_type, {
      planner: 0,
      coder: 1,
      reviewer: 2,
      tester: 3
    }, prefix: true

    enum :status, {
      resting: "resting",
      working: "working",
      waiting: "waiting"
    }, prefix: true

    validates :agent_type, presence: true
    validates :status, presence: true

    # Add broadcast_refreshes if the host app has it set up
    if defined?(ApplicationRecord.broadcast_refreshes)
      broadcasts_refreshes
    end

    # Chat interface - send message and get response
    def chat(message, llm_model: nil, tools: nil, async: false, user_id: nil)
      update(status: :working)
      target_llm_model = llm_model || get_default_llm_model
      llm_provider = target_llm_model.llm_provider
      tool_classes = tools || get_default_tools
      resolved_user_id = user_id || Thread.current[:current_user_id]
      
      user_message = messages.create!(
        role: 'user',
        content: message,
        user_id: resolved_user_id
      )
      
      if async
        LlmToolkit::CallLlmJob.perform_later(
          id,
          target_llm_model.id,
          tool_classes.map(&:name),
          self.agent_type,
          resolved_user_id
        )
        return true
      else
        service = LlmToolkit::CallLlmWithToolService.new(
          llm_model: target_llm_model,
          conversation: self,
          tool_classes: tool_classes,
          user_id: resolved_user_id
        )
        result = service.call
        messages.where(role: 'assistant').order(created_at: :desc).first if result
      end
    end

    # Streaming chat interface - works with both Anthropic and OpenRouter providers
    def stream_chat(message, llm_model: nil, tools: nil, broadcast_to: nil, async: true, user_id: nil)
      target_llm_model = llm_model || get_default_llm_model
      llm_provider = target_llm_model.llm_provider

      unless llm_provider.supports_streaming?
        raise ArgumentError, "stream_chat requires a provider that supports streaming (anthropic or openrouter)"
      end

      update(status: :working)
      tool_classes = tools || get_default_tools
      resolved_user_id = user_id || Thread.current[:current_user_id]
      
      user_message = messages.create!(
        role: 'user',
        content: message,
        user_id: resolved_user_id
      )
      
      if async
        LlmToolkit::CallStreamingLlmJob.perform_later(
          id,
          target_llm_model.id,
          resolved_user_id,
          tool_classes.map(&:name),
          broadcast_to
        )
        return true
      else
        service = LlmToolkit::CallStreamingLlmWithToolService.new(
          llm_model: target_llm_model,
          conversation: self,
          tool_classes: tool_classes,
          user_id: resolved_user_id
        )
        result = service.call
        messages.where(role: 'assistant').order(created_at: :desc).first if result
      end
    end

    def chat_async(message, llm_model: nil, tools: nil, user_id: nil)
      chat(message, llm_model: llm_model, tools: tools, async: true, user_id: user_id)
    end

    def stream_chat_async(message, llm_model: nil, tools: nil, broadcast_to: nil, user_id: nil)
      stream_chat(message, llm_model: llm_model, tools: tools, broadcast_to: broadcast_to, async: true, user_id: user_id)
    end

    def working?
      status == "working"
    end

    def waiting?
      status == "waiting"
    end

    def can_send_message?
      status_resting? || canceled?
    end

    def can_retry?
      status_resting? && messages.last&.is_error?
    end

    # Returns an array of messages formatted for LLM providers
    def history(llm_model: nil)
      target_llm_model = llm_model || get_default_llm_model
      provider_type = target_llm_model.llm_provider.provider_type
      raise ArgumentError, "Invalid provider type derived from model" unless ["anthropic", "openrouter"].include?(provider_type)

      history_messages = []

      messages.non_error.order(:created_at).each do |message|
        llm_message = { role: message.role }
        tool_uses = message.tool_uses

        if message.user_message?
          content_parts = []
          content_parts << { type: "text", text: message.content.presence || "" }

          if message.attachments.attached? && provider_type == 'openrouter'
            message.attachments.each do |attachment|
              begin
                blob_data = attachment.blob.download
                base64_data = Base64.strict_encode64(blob_data)

                if attachment.image? && ['image/jpeg', 'image/png', 'image/webp'].include?(attachment.content_type)
                  data_url = "data:#{attachment.content_type};base64,#{base64_data}"
                  content_parts << { type: "image_url", image_url: { url: data_url } }
                elsif attachment.content_type == 'application/pdf'
                  data_url = "data:application/pdf;base64,#{base64_data}"
                  content_parts << {
                    type: "file",
                    file: {
                      filename: attachment.filename.to_s,
                      file_data: data_url
                    }
                  }
                else
                  Rails.logger.warn "Unsupported attachment type for LLM: #{attachment.content_type}, filename: #{attachment.filename}"
                end
              rescue => e
                Rails.logger.error "Error processing attachment #{attachment.id} for LLM: #{e.message}"
              end
            end
          end
          
          llm_message[:content] = content_parts

        elsif message.llm_content?
          llm_message[:content] = message.content.presence
        else
          llm_message[:content] = message.content.presence
        end

        if tool_uses.any?
          case provider_type
          when "anthropic"
            history_messages += format_anthropic_message(llm_message, tool_uses)
          when "openrouter"
            history_messages += format_openrouter_message(llm_message, tool_uses)
          end
        else
          if llm_message[:content].present? || llm_message[:role] == 'user'
            if llm_message[:role] == 'assistant'
              if llm_message[:content].is_a?(Array)
                text_part = llm_message[:content].find { |part| part[:type] == 'text' }
                llm_message[:content] = text_part ? text_part[:text] : ""
              end
            elsif llm_message[:role] == 'user'
              if provider_type == 'openrouter' && llm_message[:content].is_a?(String)
                llm_message[:content] = [{ type: "text", text: llm_message[:content] }]
              elsif provider_type == 'anthropic' && llm_message[:content].is_a?(Array)
                text_part = llm_message[:content].find { |part| part[:type] == 'text' }
                llm_message[:content] = text_part ? text_part[:text] : ""
              end
            end
            history_messages << llm_message
          end
        end
      end

      if provider_type == "anthropic"
        add_cache_control(history_messages)
      end

      # Filter out empty messages, but NEVER filter out 'tool' messages
      filtered_messages = history_messages.reject do |msg|
        next false if msg[:role] == 'tool'
        
        is_empty_non_user = msg[:role] != 'user' && msg[:content].blank? && msg[:tool_calls].blank?
        is_empty_user = if provider_type == "anthropic"
                          msg[:role] == 'user' && msg[:content].blank?
                        else
                          msg[:role] == 'user' && msg[:content].is_a?(Array) && msg[:content].all? { |p| p[:type] == 'text' && p[:text].blank? }
                        end
        is_empty_non_user || is_empty_user
      end
      
      # Repair invalid sequences: tool -> user must have an assistant message in between
      repair_tool_user_sequences(filtered_messages, provider_type)
    end

    private

    # Repairs invalid message sequences where a tool result is followed directly by a user message
    # without an assistant response in between. This can happen when:
    # 1. An error occurs during the followup call after a tool execution
    # 2. The error message is saved with is_error: true (and thus excluded from history)
    # 3. The user sends a new message
    # Result: tool -> user (invalid for OpenAI/OpenRouter API which expects tool -> assistant -> user)
    #
    # This method injects a synthetic assistant message to make the sequence valid.
    def repair_tool_user_sequences(messages, provider_type)
      return messages if messages.empty?
      
      repaired = []
      
      messages.each_with_index do |msg, i|
        # Check if we need to inject a synthetic assistant message
        if i > 0 && msg[:role] == 'user'
          prev_msg = repaired.last
          
          if prev_msg && prev_msg[:role] == 'tool'
            # Invalid sequence detected: tool -> user
            # Inject a synthetic assistant message
            Rails.logger.warn("[CONVERSATION HISTORY REPAIR] Detected invalid tool->user sequence at index #{i}, injecting synthetic assistant message")
            
            synthetic_assistant = build_synthetic_assistant_message(provider_type)
            repaired << synthetic_assistant
          end
        end
        
        repaired << msg
      end
      
      repaired
    end
    
    # Builds a synthetic assistant message to repair broken sequences
    def build_synthetic_assistant_message(provider_type)
      content = "[Une erreur s'est produite lors du traitement précédent. Veuillez continuer.]"
      
      case provider_type
      when "anthropic"
        { role: "assistant", content: content }
      when "openrouter"
        { role: "assistant", content: content }
      else
        { role: "assistant", content: content }
      end
    end

    def get_default_provider
      if conversable.respond_to?(conversable.class.get_default_llm_provider_method)
        conversable.send(conversable.class.get_default_llm_provider_method)
      else
        conversable.default_llm_provider
      end
    end
    
    def get_default_llm_model
      provider = get_default_provider
      model = provider.llm_models.ordered.first
      unless model
        raise "No LLM model found for provider #{provider.name}"
      end
      model
    end

    def get_default_tools
      conversable.class.default_tools
    end

    def format_anthropic_message(message_content, tool_uses)
      base_content = message_content[:content]
      if base_content.is_a?(String)
        message_content[:content] = [{ type: "text", text: base_content }]
      elsif base_content.nil?
         message_content[:content] = []
      end
      
      messages = [{
        role: message_content[:role],
        content: message_content[:content]
      }]
      
      tool_uses.each do |tool_use|
        messages.first[:content] ||= []
        messages.first[:content] << {
          type: "tool_use",
          id: tool_use.tool_use_id,
          name: tool_use.name,
          input: tool_use.input
        }

        if tool_result = tool_use.tool_result
          is_error_value = tool_result.is_error.nil? ? false : !!tool_result.is_error
          sanitized_content = sanitize_tool_result_content(tool_result.content, tool_use.name)
          
          messages << {
            role: "user",
            content: [{
              type: "tool_result",
              tool_use_id: tool_use.tool_use_id,
              content: sanitized_content,
              is_error: is_error_value
            }]
          }
        else
          Rails.logger.warn("Tool use #{tool_use.id} (#{tool_use.name}) has no tool_result - creating synthetic error response")
          messages << {
            role: "user",
            content: [{
              type: "tool_result",
              tool_use_id: tool_use.tool_use_id,
              content: "Tool execution failed or was interrupted. No result was received.",
              is_error: true
            }]
          }
        end
      end

      messages
    end

    def format_openrouter_message(message_content, tool_uses)
      messages = [message_content] 
      
      is_assistant_only_tools = message_content[:role] == 'assistant' && message_content[:content].blank?
      messages.shift if is_assistant_only_tools

      assistant_tool_call_message = nil
      tool_result_messages = []

      tool_uses.each do |tool_use|
        tool_id = tool_use.tool_use_id.presence || "tool_#{SecureRandom.hex(4)}_#{tool_use.name}"
        
        tool_arguments = begin
          if tool_use.input.is_a?(Hash)
            tool_use.input.to_json
          else
            JSON.generate({})
          end
        rescue JSON::GeneratorError => e
          Rails.logger.error("Error serializing tool arguments for tool #{tool_use.name} (ID: #{tool_id}): #{e.message}")
          "{ \"error\": \"Failed to serialize arguments\" }"
        rescue => e
           Rails.logger.error("Unexpected error serializing tool arguments for tool #{tool_use.name} (ID: #{tool_id}): #{e.message}")
           "{ \"error\": \"Unexpected error serializing arguments\" }"
        end
        
        unless assistant_tool_call_message
          assistant_tool_call_message = {
            role: "assistant",
            content: "",
            tool_calls: []
          }
        end
        
        assistant_tool_call_message[:tool_calls] << {
          id: tool_id,
          type: "function",
          function: {
            name: tool_use.name,
            arguments: tool_arguments
          }
        }

        if tool_result = tool_use.tool_result
          tool_result_content = tool_result.content.to_s
          
          if tool_result_content.include?('=>') && tool_result_content.strip.start_with?('{') && tool_result_content.strip.end_with?('}')
             begin
               parsed = JSON.parse(tool_result_content)
               tool_result_content = parsed.to_json
             rescue JSON::ParserError
               Rails.logger.warn("Ruby hash notation detected in tool result, attempting cleanup for tool #{tool_use.name}")
               
               if tool_result_content =~ /:result\s*=>\s*"(.*)"\s*\}/m
                 extracted_content = $1
                 tool_result_content = extracted_content.gsub('\\"', '"').gsub('\\n', "\n").gsub('\\\\', '\\')
               else
                 Rails.logger.warn("Could not reliably clean Ruby hash notation for tool #{tool_use.name}")
               end
             end
          end
          
          image_data = extract_image_from_tool_result(tool_result_content, tool_use.name)
          tool_result_content = sanitize_tool_result_content(tool_result_content, tool_use.name)
          
          if tool_result_content.blank?
            tool_result_content = "[Tool completed with empty response]"
          end
          
          tool_result_messages << {
            role: "tool",
            tool_call_id: tool_id,
            name: tool_use.name,
            content: tool_result_content
          }
          
          if image_data
            Rails.logger.info("📸 Adding screenshot image to conversation for tool #{tool_use.name}")
            tool_result_messages << create_image_user_message(image_data, tool_use.name)
          end
        else
          Rails.logger.warn("Tool use #{tool_use.id} (#{tool_use.name}) has no tool_result - creating synthetic error response for OpenRouter")
          
          error_message = case tool_use.status
          when 'pending'
            "Tool execution is pending approval and has not been executed yet."
          when 'rejected'
            "Tool execution was rejected by the user."
          else
            "Tool execution failed, timed out, or was interrupted. No result was received."
          end
          
          tool_result_messages << {
            role: "tool",
            tool_call_id: tool_id,
            name: tool_use.name,
            content: error_message
          }
        end
      end
      
      messages << assistant_tool_call_message if assistant_tool_call_message
      messages += tool_result_messages
      
      Rails.logger.debug("Formatted OpenRouter messages: #{messages.inspect}")
      
      messages
    end

    def extract_image_from_tool_result(content, tool_name)
      return nil if content.blank?
      
      content_str = content.to_s
      
      screenshot_tools = %w[
        lovelace_browser_screenshot
        lovelace_browser_get_state
        lovelace_cua_assistant
      ]
      
      return nil unless screenshot_tools.include?(tool_name)
      
      if match = content_str.match(/:data\s*=>\s*"([A-Za-z0-9+\/=]+)"/)
        base64_data = match[1]
        if base64_data.length > 100
          Rails.logger.info("📸 Extracted image from Ruby hash notation (#{base64_data.length} chars)")
          return "data:image/png;base64,#{base64_data}"
        end
      end
      
      if match = content_str.match(/"data"\s*:\s*"([A-Za-z0-9+\/=]+)"/)
        base64_data = match[1]
        if base64_data.length > 100
          Rails.logger.info("📸 Extracted image from JSON format (#{base64_data.length} chars)")
          return "data:image/png;base64,#{base64_data}"
        end
      end
      
      if match = content_str.match(/(data:image\/[a-z]+;base64,[A-Za-z0-9+\/=]+)/)
        data_url = match[1]
        if data_url.length > 100
          Rails.logger.info("📸 Extracted existing data URL (#{data_url.length} chars)")
          return data_url
        end
      end
      
      nil
    end

    def create_image_user_message(image_data_url, tool_name)
      {
        role: "user",
        content: [
          {
            type: "text",
            text: "Voici la capture d'écran du navigateur suite à l'action #{tool_name}. Analyse cette image pour comprendre l'état actuel de la page."
          },
          {
            type: "image_url",
            image_url: {
              url: image_data_url
            }
          }
        ]
      }
    end

    def sanitize_tool_result_content(content, tool_name)
      return content if content.blank?

      content_str = content.to_s
      max_size = LlmToolkit.config.max_tool_result_size

      # Only process screenshot/image data if it looks like actual base64 image data
      # NOT just source code that mentions these terms
      # 
      # Detection criteria:
      # 1. Must have a long base64 string (at least 1000 chars of base64 data)
      # 2. Must be in a structured format (JSON or Ruby hash with specific keys)
      #
      # This prevents false positives when reading source code files that contain
      # the words "image_base64" or "data:image" as literals
      if looks_like_actual_screenshot_data?(content_str)
        if content_str =~ /:message\s*=>\s*"([^"]+)"/
          return "[Screenshot captured successfully] #{$1}"
        elsif content_str =~ /"message"\s*:\s*"([^"]+)"/
          return "[Screenshot captured successfully] #{$1}"
        else
          return "[Screenshot captured successfully - image sent separately for visual analysis]"
        end
      end

      # Same for PDF - only match actual base64 PDF data, not source code mentioning it
      if looks_like_actual_pdf_data?(content_str)
        return "[PDF content processed - base64 data removed for brevity]"
      end

      if content_str.length > max_size
        Rails.logger.warn("Truncating large tool result for #{tool_name}: #{content_str.length} chars -> #{max_size} chars")
        return content_str[0...max_size] + "\n\n[... content truncated due to size ...]"
      end

      content_str
    end

    # Check if content looks like actual screenshot/image data (not source code)
    # Real screenshot data will have:
    # - A long base64 string (images are typically > 10KB = 13K+ base64 chars)
    # - Structured format with data field containing the base64
    def looks_like_actual_screenshot_data?(content_str)
      return false unless content_str.include?('image_base64') || content_str.include?('data:image')

      # Check for actual base64 data pattern: a long string of base64 characters
      # Real image base64 will have 10,000+ chars of continuous base64
      # Source code mentioning "image_base64" will not have this pattern
      has_long_base64 = content_str =~ /[A-Za-z0-9+\/]{1000,}={0,2}/

      # Also check it's in a data structure format (JSON or Ruby hash)
      # with keys that indicate it's screenshot result data
      has_data_structure = content_str =~ /["']?(?:data|image_base64|screenshot)["']?\s*[=:>]/i

      has_long_base64 && has_data_structure
    end

    # Check if content looks like actual PDF base64 data (not source code)
    def looks_like_actual_pdf_data?(content_str)
      return false unless content_str.include?('data:application/pdf;base64')

      # Real PDF base64 will have thousands of chars after the prefix
      # Match the data URI followed by a long base64 string
      content_str =~ /data:application\/pdf;base64,[A-Za-z0-9+\/]{1000,}={0,2}/
    end

    def format_non_coder_tool_results(tool_uses)
      tool_uses.map do |tool_use|
        next unless tool_result = tool_use.tool_result
        result_content = if tool_result.diff.present?
          tool_result.diff
        elsif tool_result.content.present?
          tool_result.content
        else
          "Empty string"
        end
        result_content
      end.compact.join("\n\n")
    end

    def add_cache_control(history_messages)
      user_messages = history_messages.select { |msg| msg[:role] == "user" }
      last_two_user_messages = user_messages.last(2)
      
      last_two_user_messages.each do |msg|
        if msg[:content].is_a?(Array) && msg[:content].any?
          if msg[:content].last.is_a?(Hash)
            msg[:content].last[:cache_control] = { type: "ephemeral" }
          end
        end
      end
    end
  end
end
