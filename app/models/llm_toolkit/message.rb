# Include ActionView helpers needed for dom_id
include ActionView::RecordIdentifier

module LlmToolkit
  class Message < ApplicationRecord
    belongs_to :conversation, touch: true
    belongs_to :llm_model, class_name: 'LlmToolkit::LlmModel', optional: true
    has_many :tool_uses, class_name: 'LlmToolkit::ToolUse', dependent: :destroy
    has_many :tool_results, class_name: 'LlmToolkit::ToolResult', dependent: :destroy

    # Placeholder markers to detect "thinking" messages
    PLACEHOLDER_MARKERS = [
      "🤔 Traitement de votre demande...",
      "🎯 Analyse automatique en cours..."
    ].freeze

    # Broadcast when assistant messages are created or updated
    after_create_commit :broadcast_message_frame_update, if: :llm_content?
    after_update_commit :broadcast_message_frame_update, if: -> { saved_change_to_content? }
    # Broadcast usage stats update when tokens change
    after_update_commit :broadcast_usage_stats_update, if: :saved_change_to_api_total_tokens?

    # Replace the entire message frame to handle grouping properly
    # Uses broadcast_replace_to (synchronous) because locals with AR relations can't be serialized for later
    def broadcast_message_frame_update
      # Get all messages for this conversation as an array to avoid serialization issues
      all_messages = conversation.messages
                                  .includes(tool_uses: :tool_result, attachments_attachments: :blob)
                                  .order(created_at: :asc)
                                  .to_a

      broadcast_replace_to(
        conversation,                              # Stream name derived from the conversation
        target: "conversation_messages_frame",     # Target the turbo frame
        partial: "conversations/conversation_messages_frame",
        locals: { messages: all_messages }
      )
    rescue => e
      Rails.logger.error("Error broadcasting message frame update: #{e.message}")
    end
    
    # Attachments for user uploads (images, PDFs)
    has_many_attached :attachments

    validates :role, presence: true
    
    # Support for ActiveStorage if it's available and properly set up
    if defined?(ActiveStorage) && ActiveRecord::Base.connection.table_exists?('active_storage_attachments')
      has_many_attached :images
      after_save :deduplicate_images, if: -> { images.attached? }
    end

    scope :non_error, -> { where(is_error: [nil, false]) }

    # Check if content is a placeholder
    def placeholder_content?
      return true if content.blank?
      PLACEHOLDER_MARKERS.any? { |marker| content.strip == marker }
    end
    
    # Check if has real content (not placeholder)
    def has_real_content?
      !placeholder_content?
    end
    
    # =====================================================
    # REASONING SUPPORT (OpenRouter compatible)
    # =====================================================
    # OpenRouter returns reasoning in `reasoning_details` array with types:
    # - reasoning.summary: High-level summary
    # - reasoning.encrypted: Encrypted/redacted reasoning
    # - reasoning.text: Raw text reasoning with optional signature
    #
    # We store:
    # - reasoning_content: Human-readable reasoning text (for display)
    # - reasoning_details: Full OpenRouter format array (for API calls)
    # =====================================================
    
    # Check if message has reasoning data
    def has_reasoning?
      reasoning_content.present? || reasoning_details.present?
    end
    
    # Get displayable reasoning text
    # Extracts text from reasoning_details if reasoning_content is not set
    def displayable_reasoning
      return reasoning_content if reasoning_content.present?
      return nil if reasoning_details.blank?
      
      extract_reasoning_text_from_details
    end
    
    # Set reasoning from OpenRouter response format
    # @param details [Array] Array of reasoning_details objects from OpenRouter
    def set_reasoning_from_openrouter(details)
      return if details.blank?
      
      self.reasoning_details = details
      self.reasoning_content = extract_reasoning_text_from_details
    end
    
    # Set reasoning from OpenAI CUA format
    # @param reasoning_items [Array] Array of reasoning items from OpenAI CUA
    def set_reasoning_from_openai_cua(reasoning_items)
      return if reasoning_items.blank?
      
      # Convert OpenAI CUA format to OpenRouter-compatible format
      converted_details = reasoning_items.map.with_index do |item, index|
        text = extract_openai_cua_reasoning_text(item)
        next nil if text.blank?
        
        {
          "type" => "reasoning.text",
          "text" => text,
          "id" => item['id'] || "reasoning-#{index}",
          "format" => "openai-responses-v1",
          "index" => index
        }
      end.compact
      
      self.reasoning_details = converted_details if converted_details.any?
      self.reasoning_content = converted_details.map { |d| d['text'] }.join("\n\n")
    end
    
    # Build reasoning for API call (OpenRouter format)
    # Used when passing assistant messages back in conversation history
    def reasoning_for_api
      return nil unless reasoning_details.present?
      reasoning_details
    end
    
    # For LLM conversation history - include reasoning_details if present
    def for_llm_with_reasoning(llm_role = :coder, provider_type = "anthropic")
      base = for_llm(llm_role, provider_type)
      
      # Add reasoning_details for assistant messages when using OpenRouter
      if role == 'assistant' && reasoning_details.present? && provider_type == "openrouter"
        base[:reasoning_details] = reasoning_details
      end
      
      base
    end

    def for_llm(llm_role = :coder, provider_type = "anthropic")
      if llm_role == :coder
        if role == 'user'
          if content.blank? && provider_type == "openrouter"
            {role: role, content: nil}
          else
            {role: role, content: [type: "text", text: content.blank? ? "Empty message" : content]}
          end
        else 
          {role: role, content: content.blank? ? nil : content}
        end
      else 
        if role == 'user'
          {role: "assistant", content: [type: "text", text: content]}
        else 
          {role: "user", content: content.blank? ? "Empty message" : content}
        end
      end
    end

    def user_message?
      role == 'user'
    end

    def llm_content?
      role == 'assistant'
    end

    def total_tokens
      (prompt_tokens.to_i + completion_tokens.to_i).nonzero? || 
        (input_tokens.to_i + cache_creation_input_tokens.to_i + cache_read_input_tokens.to_i + output_tokens.to_i)
    end

    # Calculate cost based on model pricing if available, otherwise use fallback rates
    def calculate_cost
      pricing = llm_model&.model_pricing
      
      if pricing
        # Use the model's pricing from ModelPricing
        prompt_cost = (prompt_tokens.to_i * pricing.prompt_price_per_million_tokens.to_f) / 1_000_000
        completion_cost = (completion_tokens.to_i * pricing.completion_price_per_million_tokens.to_f) / 1_000_000
        prompt_cost + completion_cost
      else
        # Fallback to hardcoded rates (Claude-like pricing)
        (input_tokens.to_i * 0.000003) +
        (cache_creation_input_tokens.to_i * 0.00000375) +
        (cache_read_input_tokens.to_i * 0.0000003) +
        (output_tokens.to_i * 0.000015)
      end
    end
    
    # Check if we have cost data to display
    def has_cost_data?
      prompt_tokens.to_i > 0 || completion_tokens.to_i > 0 || 
        input_tokens.to_i > 0 || output_tokens.to_i > 0
    end
    
    # For backward compatibility - returns false if ActiveStorage isn't available
    def images_attached?
      return false unless respond_to?(:images)
      images.attached?
    end
    
    # Provides a user-friendly description of the finish_reason
    def finish_reason_description
      case finish_reason
      when 'stop'
        'Model completed response normally'
      when 'length'
        'Response cut off due to token limit'
      when 'tool_calls'
        'Model called tools to complete the task'
      when 'content_filter'
        'Content was filtered due to safety concerns'
      when nil
        'No finish reason provided'
      else
        finish_reason.to_s.humanize
      end
    end
    
    private
    
    # Extract human-readable text from reasoning_details array
    def extract_reasoning_text_from_details
      return nil if reasoning_details.blank?
      
      texts = reasoning_details.map do |detail|
        case detail['type']
        when 'reasoning.summary'
          detail['summary']
        when 'reasoning.text'
          detail['text']
        when 'reasoning.encrypted'
          "[Reasoning encrypted]"
        else
          nil
        end
      end.compact
      
      texts.any? ? texts.join("\n\n") : nil
    end
    
    # Extract text from OpenAI CUA reasoning item
    def extract_openai_cua_reasoning_text(item)
      # OpenAI CUA reasoning items can have different structures
      if item['summary'].is_a?(Array)
        # New format: summary is array of objects with type/text
        item['summary'].map { |s| s['text'] if s['type'] == 'summary_text' }.compact.join("\n")
      elsif item['summary'].is_a?(String)
        item['summary']
      elsif item['content'].is_a?(String)
        item['content']
      elsif item['text'].is_a?(String)
        item['text']
      else
        nil
      end
    end
    
    # Broadcasts an update to the conversation's usage stats frame
    def broadcast_usage_stats_update
      broadcast_replace_to(
        conversation,
        target: dom_id(conversation, "usage_stats"), # Target the turbo frame
        partial: "conversations/usage_stats",
        locals: { conversation: conversation }
      )
    rescue => e
      Rails.logger.error("Error broadcasting usage stats update: #{e.message}")
    end

    def deduplicate_images
      return if images.blank?

      unique_blobs = images.blobs.uniq(&:checksum)
      self.images = unique_blobs
    end
  end
end
