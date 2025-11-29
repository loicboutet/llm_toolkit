module LlmToolkit
  class Conversation < ApplicationRecord
    # Maximum size for tool results in conversation history (in characters)
    # Larger results will be truncated to prevent 413 errors
    MAX_TOOL_RESULT_SIZE = 50_000

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
    def chat(message, llm_model: nil, tools: nil, async: false)
      update(status: :working)
      target_llm_model = llm_model || get_default_llm_model
      llm_provider = target_llm_model.llm_provider
      tool_classes = tools || get_default_tools
      
      user_message = messages.create!(
        role: 'user',
        content: message,
        user_id: Thread.current[:current_user_id]
      )
      
      if async
        LlmToolkit::CallLlmJob.perform_later(
          id,
          target_llm_model.id,
          tool_classes.map(&:name),
          self.agent_type,
          Thread.current[:current_user_id]
        )
        return true
      else
        service = LlmToolkit::CallLlmWithToolService.new(
          llm_model: target_llm_model,
          conversation: self,
          tool_classes: tool_classes,
          user_id: Thread.current[:current_user_id]
        )
        result = service.call
        messages.where(role: 'assistant').order(created_at: :desc).first if result
      end
    end

    # Streaming chat interface
    def stream_chat(message, llm_model: nil, tools: nil, broadcast_to: nil, async: true)
      target_llm_model = llm_model || get_default_llm_model
      llm_provider = target_llm_model.llm_provider

      unless llm_provider.provider_type == 'openrouter'
        raise ArgumentError, "stream_chat only works with OpenRouter providers"
      end

      update(status: :working)
      tool_classes = tools || get_default_tools
      
      user_message = messages.create!(
        role: 'user',
        content: message,
        user_id: Thread.current[:current_user_id]
      )
      
      if async
        LlmToolkit::CallStreamingLlmJob.perform_later(
          id,
          target_llm_model.id,
          self.agent_type,
          Thread.current[:current_user_id],
          tool_classes.map(&:name),
          broadcast_to
        )
        return true
      else
        service = LlmToolkit::CallStreamingLlmWithToolService.new(
          llm_model: target_llm_model,
          conversation: self,
          tool_classes: tool_classes,
          user_id: Thread.current[:current_user_id]
        )
        result = service.call
        messages.where(role: 'assistant').order(created_at: :desc).first if result
      end
    end

    def chat_async(message, llm_model: nil, tools: nil)
      chat(message, llm_model: llm_model, tools: tools, async: true)
    end

    def stream_chat_async(message, llm_model: nil, tools: nil, broadcast_to: nil)
      stream_chat(message, llm_model: llm_model, tools: tools, broadcast_to: broadcast_to, async: true)
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

      return history_messages.reject do |msg|
        is_empty_non_user = msg[:role] != 'user' && msg[:content].blank? && msg[:tool_calls].blank?
        is_empty_user = if provider_type == "anthropic"
                          msg[:role] == 'user' && msg[:content].blank?
                        else
                          msg[:role] == 'user' && msg[:content].is_a?(Array) && msg[:content].all? { |p| p[:type] == 'text' && p[:text].blank? }
                        end
        is_empty_non_user || is_empty_user
      end
    end

    private

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
          
          # Sanitize tool result content to prevent oversized payloads
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
          
          # Clean up Ruby hash notation if present
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
          
          # Sanitize tool result content to prevent oversized payloads
          tool_result_content = sanitize_tool_result_content(tool_result_content, tool_use.name)
          
          tool_result_messages << {
            role: "tool",
            tool_call_id: tool_id,
            name: tool_use.name,
            content: tool_result_content
          }
        end
      end
      
      messages << assistant_tool_call_message if assistant_tool_call_message
      messages += tool_result_messages
      
      Rails.logger.debug("Formatted OpenRouter messages: #{messages.inspect}")
      
      messages
    end

    # Sanitize tool result content to prevent oversized payloads (413 errors)
    # - Removes base64 image data and replaces with a summary
    # - Truncates overly long results
    def sanitize_tool_result_content(content, tool_name)
      return content if content.blank?
      
      content_str = content.to_s
      
      # Check for base64 image data patterns
      if content_str.include?('image_base64') || content_str.include?('data:image')
        # Extract the message part if it exists, remove the base64 data
        if content_str =~ /:message\s*=>\s*"([^"]+)"/
          return "[Image captured successfully] #{$1}"
        elsif content_str =~ /"message"\s*:\s*"([^"]+)"/
          return "[Image captured successfully] #{$1}"
        else
          return "[Image captured successfully - screenshot taken]"
        end
      end
      
      # Check for base64 PDF data
      if content_str.include?('data:application/pdf;base64')
        return "[PDF content processed - base64 data removed for brevity]"
      end
      
      # Truncate if still too large
      if content_str.length > MAX_TOOL_RESULT_SIZE
        Rails.logger.warn("Truncating large tool result for #{tool_name}: #{content_str.length} chars -> #{MAX_TOOL_RESULT_SIZE} chars")
        return content_str[0...MAX_TOOL_RESULT_SIZE] + "\n\n[... content truncated due to size ...]"
      end
      
      content_str
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
