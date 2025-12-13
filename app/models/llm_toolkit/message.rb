module LlmToolkit
  class Message < ApplicationRecord
    include ActionView::RecordIdentifier
    
    belongs_to :conversation, touch: true
    belongs_to :llm_model, class_name: 'LlmToolkit::LlmModel', optional: true
    has_many :tool_uses, class_name: 'LlmToolkit::ToolUse', dependent: :destroy
    has_many :tool_results, class_name: 'LlmToolkit::ToolResult', dependent: :destroy

    PLACEHOLDER_MARKERS = [
      "🤔 Traitement de votre demande...",
      "🎯 Analyse automatique en cours..."
    ].freeze

    STREAMING_THROTTLE_MS = 50
    
    after_create_commit :broadcast_message_created, if: :llm_content?
    after_update_commit :broadcast_content_update_throttled, if: -> { saved_change_to_content? && llm_content? }
    after_update_commit :broadcast_message_complete, if: -> { saved_change_to_prompt_tokens? && llm_content? }

    def broadcast_message_created
      Rails.logger.info("[BROADCAST] Message #{id} created, broadcasting full frame replacement")
      broadcast_full_frame
    rescue => e
      Rails.logger.error("Error broadcasting message created: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
    
    def broadcast_message_complete
      Rails.logger.info("[BROADCAST] Message #{id} complete (tokens: #{prompt_tokens}), broadcasting full frame and header stats")
      broadcast_full_frame
      broadcast_header_stats
    rescue => e
      Rails.logger.error("Error broadcasting message complete: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
    
    # Broadcast the full conversation messages frame
    # Messages in CHRONOLOGICAL order (oldest first, newest at bottom)
    def broadcast_full_frame
      all_messages = conversation.messages
                                  .includes(tool_uses: :tool_result, attachments_attachments: :blob)
                                  .order(created_at: :asc)
                                  .to_a

      broadcast_replace_to(
        conversation,
        target: "conversation_messages_frame",
        partial: "conversations/conversation_messages_frame",
        locals: { messages: all_messages }
      )
    end
    
    def broadcast_header_stats
      broadcast_replace_to(
        conversation,
        target: dom_id(conversation, :header_stats),
        partial: "conversations/header_stats",
        locals: { conversation: conversation }
      )
    rescue => e
      Rails.logger.error("Error broadcasting header stats: #{e.message}")
    end
    
    def broadcast_content_update_throttled
      return if placeholder_content?
      
      throttle_key = "message_broadcast_#{id}"
      last_broadcast = Thread.current[throttle_key]
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
      
      if last_broadcast && (now - last_broadcast) < STREAMING_THROTTLE_MS
        return
      end
      
      Thread.current[throttle_key] = now
      broadcast_content_update
    end
    
    def broadcast_content_update
      rendered_content = render_markdown(content || "")
      target_id = "content_message_#{id}"
      
      Rails.logger.debug("[BROADCAST] Updating content for message #{id}, target: #{target_id}")
      
      Turbo::StreamsChannel.broadcast_replace_to(
        conversation,
        target: target_id,
        html: "<div id=\"#{target_id}\" class=\"prose-nexrai\">#{rendered_content}</div>"
      )
    rescue => e
      Rails.logger.error("Error broadcasting content update for message #{id}: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
    
    has_many_attached :attachments
    validates :role, presence: true
    
    if defined?(ActiveStorage) && ActiveRecord::Base.connection.table_exists?('active_storage_attachments')
      has_many_attached :images
      after_save :deduplicate_images, if: -> { images.attached? }
    end

    scope :non_error, -> { where(is_error: [nil, false]) }

    def placeholder_content?
      return true if content.blank?
      PLACEHOLDER_MARKERS.any? { |marker| content.strip == marker }
    end
    
    def has_real_content?
      !placeholder_content?
    end
    
    def render_markdown(text)
      return '' if text.blank?
      
      renderer = Redcarpet::Render::HTML.new(
        filter_html: false,
        hard_wrap: true,
        link_attributes: { target: '_blank', rel: 'noopener noreferrer' }
      )
      markdown = Redcarpet::Markdown.new(
        renderer,
        autolink: true,
        tables: true,
        fenced_code_blocks: true,
        strikethrough: true,
        superscript: true,
        underline: true,
        highlight: true,
        quote: true,
        footnotes: true,
        lax_spacing: true
      )
      
      markdown.render(text).html_safe
    end
    
    def has_reasoning?
      reasoning_content.present? || reasoning_details.present?
    end
    
    def displayable_reasoning
      return reasoning_content if reasoning_content.present?
      return nil if reasoning_details.blank?
      extract_reasoning_text_from_details
    end
    
    def set_reasoning_from_openrouter(details)
      return if details.blank?
      self.reasoning_details = details
      self.reasoning_content = extract_reasoning_text_from_details
    end
    
    def set_reasoning_from_openai_cua(reasoning_items)
      return if reasoning_items.blank?
      
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
    
    def reasoning_for_api
      return nil unless reasoning_details.present?
      reasoning_details
    end
    
    def for_llm_with_reasoning(llm_role = :coder, provider_type = "anthropic")
      base = for_llm(llm_role, provider_type)
      
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
      prompt_tokens.to_i + completion_tokens.to_i
    end

    def calculate_cost
      pricing = llm_model&.model_pricing
      
      if pricing
        pricing.calculate_cost(
          prompt_tokens: prompt_tokens.to_i,
          completion_tokens: completion_tokens.to_i,
          cache_read_tokens: cache_read_input_tokens.to_i,
          cache_creation_tokens: cache_creation_input_tokens.to_i
        )
      else
        prompt_cost = 0.0
        non_cached_prompts = [prompt_tokens.to_i - cache_read_input_tokens.to_i, 0].max
        prompt_cost += non_cached_prompts * 0.000003
        prompt_cost += cache_read_input_tokens.to_i * 0.0000003
        prompt_cost += cache_creation_input_tokens.to_i * 0.00000375
        completion_cost = completion_tokens.to_i * 0.000015
        prompt_cost + completion_cost
      end
    end
    
    def has_cost_data?
      prompt_tokens.to_i > 0 || completion_tokens.to_i > 0
    end
    
    def cache_stats
      cache_creation = cache_creation_input_tokens.to_i
      cache_read = cache_read_input_tokens.to_i
      prompt = prompt_tokens.to_i
      
      {
        cache_creation_tokens: cache_creation,
        cache_read_tokens: cache_read,
        has_cache: cache_creation > 0 || cache_read > 0,
        cache_hit_rate: prompt > 0 ? ((cache_read.to_f / prompt) * 100).round(1) : 0
      }
    end
    
    def images_attached?
      return false unless respond_to?(:images)
      images.attached?
    end
    
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
    
    def extract_openai_cua_reasoning_text(item)
      if item['summary'].is_a?(Array)
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

    def deduplicate_images
      return if images.blank?
      unique_blobs = images.blobs.uniq(&:checksum)
      self.images = unique_blobs
    end
  end
end
