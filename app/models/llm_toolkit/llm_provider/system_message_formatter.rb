module LlmToolkit
  class LlmProvider < ApplicationRecord
    module SystemMessageFormatter
      extend ActiveSupport::Concern
      
      private
      
      # Format system messages for OpenRouter, handling both simple and complex formats
      #
      # CACHING STRATEGY for Anthropic via OpenRouter:
      # - cache_control marks the END of a cacheable prefix
      # - Anthropic caches "everything up to this breakpoint"
      # - System messages are STATIC (don't change between requests)
      # - So we apply cache_control to the LAST content block of system messages
      # - This caches the entire system prompt for subsequent requests
      #
      # Key insight: The cache key is based on ALL content BEFORE the cache_control marker.
      # If that content matches a previous request, you get a cache HIT (0.1x price).
      # If it doesn't match, you get a cache WRITE (1.25x price).
      def format_system_messages_for_openrouter(system_messages)
        return [] if system_messages.blank?
        
        # Check if we have complex OpenRouter format (array of message objects)
        if complex_system_messages?(system_messages)
          Rails.logger.info "Using complex system message format for OpenRouter"
          return apply_cache_control_to_system_messages(system_messages)
        end
        
        # Convert simple format to OpenRouter format
        Rails.logger.info "Converting simple system messages to OpenRouter format"
        system_message_content = system_messages.map { |msg| 
          msg.is_a?(Hash) ? msg[:text] : msg.to_s 
        }.join("\n")
        
        content_item = { type: 'text', text: system_message_content }
        
        # Apply cache control - system messages are static, so cache them
        if caching_enabled?
          content_item[:cache_control] = { type: 'ephemeral' }
          Rails.logger.info "[SYSTEM CACHE] Applied cache_control to system message (#{system_message_content.length} chars)"
        end
        
        [{
          role: 'system',
          content: [content_item]
        }]
      end
      
      # Apply cache_control to system messages
      # 
      # Strategy: Apply to the LAST text block of the LAST system message.
      # This caches the entire system prompt since it comes first in the request.
      #
      # Why the last block? Because Anthropic's cache_control means:
      # "Cache everything in the request UP TO AND INCLUDING this block"
      #
      # Note: Anthropic has a limit of 4 cache_control blocks total.
      # We use 1 for system messages, leaving 3 for conversation history.
      def apply_cache_control_to_system_messages(messages)
        return messages unless caching_enabled?
        
        # Find the last text block across all system messages
        last_msg_index = nil
        last_content_index = nil
        total_system_chars = 0
        
        messages.each_with_index do |msg, msg_idx|
          next unless msg[:content].is_a?(Array) && msg[:content].any?
          
          msg[:content].each_with_index do |content_item, content_idx|
            if content_item[:type] == 'text'
              last_msg_index = msg_idx
              last_content_index = content_idx
              total_system_chars += content_item[:text]&.length.to_i
            end
          end
        end
        
        # No text content found
        return messages if last_msg_index.nil?
        
        # Apply cache_control to the last text block (end of system prompt)
        messages.each_with_index.map do |msg, msg_idx|
          next msg unless msg[:content].is_a?(Array)
          
          updated_content = msg[:content].each_with_index.map do |content_item, content_idx|
            if msg_idx == last_msg_index && content_idx == last_content_index
              content_item = content_item.dup
              content_item[:cache_control] = { type: 'ephemeral' }
              Rails.logger.info "[SYSTEM CACHE] Applied cache_control to end of system messages (#{total_system_chars} total chars cached)"
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
          # Simple format
          system_messages.map { |msg| 
            msg.is_a?(Hash) ? msg[:text] : msg.to_s 
          }.join("\n")
        end
      end
    end
  end
end
