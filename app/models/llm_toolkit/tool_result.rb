module LlmToolkit
  class ToolResult < ApplicationRecord
    # Include ActionView helpers needed for dom_id in broadcasts
    include ActionView::RecordIdentifier
    
    belongs_to :message, class_name: 'LlmToolkit::Message'
    belongs_to :tool_use, class_name: 'LlmToolkit::ToolUse'
    
    after_create :touch_conversation
    after_update :touch_conversation
    after_destroy :touch_conversation

    # Broadcast changes to the conversation stream
    after_create_commit :broadcast_to_tool_use
    after_update_commit :broadcast_to_tool_use
    
    # Ensure is_error is always a boolean
    before_save :ensure_is_error_boolean
    
    private
    
    def ensure_is_error_boolean
      # Convert nil to false, and ensure any other value is explicitly a boolean
      self.is_error = self.is_error.nil? ? false : !!self.is_error
    end
    
    def touch_conversation
      message.conversation.touch
    end

    # Broadcasts replacing the result container within the tool use partial
    def broadcast_to_tool_use
      Rails.logger.info("[BROADCAST] ToolResult #{id} broadcasting to tool_use #{tool_use.id}")
      
      broadcast_replace_later_to(
        message.conversation,               # Stream name derived from the conversation
        target: dom_id(tool_use, :result_container), # Target the container within the tool_use partial
        partial: "tool_results/tool_result", # The specific tool result partial
        locals: { tool_result: self }
      )
    rescue => e
      Rails.logger.error("Error broadcasting tool result: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
  end
end
