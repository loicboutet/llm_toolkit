module LlmToolkit
  class LlmProvider < ApplicationRecord
    module SystemMessageFormatter
      extend ActiveSupport::Concern
      
      private
      
      # Format system messages for OpenRouter, handling both simple and complex formats
      # Applies cache_control ONLY to the last content block (regardless of size)
      # This ensures we stay within Anthropic's 4 cache_control block limit
      def format_system_messages_for_openrouter(system_messages)
        return [] if system_messages.blank?
        
        # Check if we have complex OpenRouter format (array of message objects)
        if complex_system_messages?(system_messages)
          Rails.logger.info "Using complex system message format for OpenRouter"
          return apply_cache_control_to_last_block(system_messages)
        end
        
        # Convert simple format to OpenRouter format
        Rails.logger.info "Converting simple system messages to OpenRouter format"
        system_message_content = system_messages.map { |msg| 
          msg.is_a?(Hash) ? msg[:text] : msg.to_s 
        }.join("\n")
        
        content_item = { type: 'text', text: system_message_content }
        
        # Apply cache control to the single content block (it's the last/only one)
        if caching_enabled?
          content_item[:cache_control] = { type: 'ephemeral' }
          Rails.logger.info "[SYSTEM CACHE] Applied cache_control to system message (#{system_message_content.length} chars)"
        end
        
        [{
          role: 'system',
          content: [content_item]
        }]
      end
      
      # Apply cache_control ONLY to the last content block in complex messages
      # This respects Anthropic's limit of 4 cache_control blocks maximum
      def apply_cache_control_to_last_block(messages)
        return messages unless caching_enabled?
        
        # Find the last message and its last content block
        # We need to track the global last block across all messages
        last_msg_index = nil
        last_content_index = nil
        
        messages.each_with_index do |msg, msg_idx|
          next unless msg[:content].is_a?(Array) && msg[:content].any?
          
          # Find the last text block in this message
          msg[:content].each_with_index do |content_item, content_idx|
            if content_item[:type] == 'text'
              last_msg_index = msg_idx
              last_content_index = content_idx
            end
          end
        end
        
        # No text content found
        return messages if last_msg_index.nil?
        
        # Apply cache_control only to the last text block
        messages.each_with_index.map do |msg, msg_idx|
          next msg unless msg[:content].is_a?(Array)
          
          updated_content = msg[:content].each_with_index.map do |content_item, content_idx|
            # Only apply to the very last text block
            if msg_idx == last_msg_index && content_idx == last_content_index
              content_item = content_item.dup
              content_item[:cache_control] = { type: 'ephemeral' }
              Rails.logger.info "[SYSTEM CACHE] Applied cache_control to last content block (#{content_item[:text]&.length || 0} chars)"
            end
            content_item
          end
          
          msg.merge(content: updated_content)
        end
      end
      
      # Check if caching is enabled in configuration
      def caching_enabled?
        LlmToolkit.config.enable_prompt_caching
      end
      
      # Get the cache threshold from configuration (kept for backward compatibility)
      def cache_threshold
        LlmToolkit.config.cache_text_threshold || 2048
      end
      
      # Check if system messages are in complex OpenRouter format
      def complex_system_messages?(system_messages)
        return false unless system_messages.is_a?(Array)
        return false if system_messages.empty?
        
        # Complex format: array of message objects with role and content
        system_messages.all? do |msg|
          msg.is_a?(Hash) && 
          msg[:role].present? && 
          msg[:content].is_a?(Array) &&
          msg[:content].all? { |content_item| content_item.is_a?(Hash) && content_item[:type].present? }
        end
      end
      
      # Format system messages for Anthropic (keep existing simple format)
      def format_system_messages_for_anthropic(system_messages)
        return "You are an AI assistant." if system_messages.blank?
        
        # For Anthropic, we only use the text content from system messages
        if complex_system_messages?(system_messages)
          # Extract text from complex format
          text_parts = []
          system_messages.each do |msg|
            msg[:content].each do |content_item|
              if content_item[:type] == 'text'
                text_parts << content_item[:text]
              end
            end
          end
          text_parts.join("\n")
        else
          # Simple format
          system_messages.map { |msg| 
            msg.is_a?(Hash) ? msg[:text] : msg.to_s 
          }.join("\n")
        end
      end
    end
  end
end
