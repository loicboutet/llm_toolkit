module LlmToolkit
  class LlmProvider < ApplicationRecord
    module SystemMessageFormatter
      extend ActiveSupport::Concern
      
      private
      
      # Format system messages for OpenRouter
      #
      # IMPORTANT: We do NOT add cache_control here!
      # 
      # Why? Because Anthropic caches the prefix UP TO the cache_control marker.
      # If we put cache_control on both system AND conversation messages,
      # only the content up to the FIRST marker gets cached on a hit.
      #
      # Instead, we let the conversation handler put cache_control on the 
      # LAST message, which caches EVERYTHING (system + entire conversation).
      #
      # Example:
      #   [System] [User1] [Asst1] [User2<cache_control>]
      #   └────────────────────────────────────────────┘
      #            Entire prefix gets cached!
      #
      def format_system_messages_for_openrouter(system_messages)
        return [] if system_messages.blank?
        
        # Check if we have complex OpenRouter format (array of message objects)
        if complex_system_messages?(system_messages)
          Rails.logger.info "Using complex system message format for OpenRouter (no cache_control here)"
          return system_messages  # Return as-is, no cache_control added
        end
        
        # Convert simple format to OpenRouter format
        Rails.logger.info "Converting simple system messages to OpenRouter format (no cache_control here)"
        system_message_content = system_messages.map { |msg| 
          extract_text_from_message(msg)
        }.compact.join("\n")
        
        # NO cache_control here - it will be added to the last conversation message
        content_item = { type: 'text', text: system_message_content }
        
        [{
          role: 'system',
          content: [content_item]
        }]
      end
      
      # Extract text content from a message in various formats
      # Supports: { content: "..." }, { text: "..." }, plain strings, etc.
      def extract_text_from_message(msg)
        return msg.to_s unless msg.is_a?(Hash)
        
        # Try various keys that might contain the text
        text = msg[:content] || msg[:text] || msg['content'] || msg['text']
        
        return nil if text.nil?
        
        # If it's an array (complex content), extract text from it
        if text.is_a?(Array)
          text.map { |item|
            if item.is_a?(Hash)
              item[:text] || item['text']
            else
              item.to_s
            end
          }.compact.join("\n")
        else
          text.to_s
        end
      end
      
      # Check if caching is enabled in configuration
      def caching_enabled?
        LlmToolkit.config.enable_prompt_caching
      end
      
      # Get the cache threshold from configuration
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
          # Simple format - use extract_text_from_message for consistency
          system_messages.map { |msg| 
            extract_text_from_message(msg)
          }.compact.join("\n")
        end
      end
    end
  end
end
