module LlmToolkit
  class ToolUse < ApplicationRecord
    # Include ActionView helpers needed for dom_id in broadcasts
    include ActionView::RecordIdentifier
    
    belongs_to :message, class_name: 'LlmToolkit::Message'
    has_one :tool_result, class_name: 'LlmToolkit::ToolResult', dependent: :destroy
    
    # The sub-agent conversation spawned by this tool_use (if it's a sub_agent tool)
    # Uses spawning_tool_use_id on Conversation for the reverse lookup
    has_one :spawned_conversation, class_name: 'LlmToolkit::Conversation', foreign_key: :spawning_tool_use_id
    
    # Explicitly declare the attribute type
    attribute :status, :integer
    enum :status, { pending: 0, approved: 1, rejected: 2, waiting: 3 }, prefix: true
      
    after_create :touch_conversation
    after_update :touch_conversation
    after_destroy :touch_conversation

    # NOTE: We do NOT broadcast on create because the Message model's broadcast_full_frame
    # will include all tool_uses when it re-renders the conversation.
    # Broadcasting on create would cause duplicates.
    
    # Only broadcast on UPDATE to refresh status changes (approved, rejected, etc.)
    after_update_commit :broadcast_replace_in_message

    def dangerous?
      LlmToolkit.config.dangerous_tools.include?(name)
    end

    def completed?
      !status_pending? && !status_waiting?
    end
    
    # Check if this tool_use spawned a sub-agent conversation
    def spawned_sub_agent?
      name == 'sub_agent' && spawned_conversation.present?
    end
    
    def file_content
      if name == 'write_to_file' && status_approved?
        File.read(input['path'])
      end
    rescue Errno::ENOENT
      "File not found: #{input['path']}"
    end
    
    def reject_with_message(rejection_message)
      create_tool_result!(
        message: message,
        content: rejection_message,
        is_error: false
      )
      status_rejected!
    end
    
    private
    
    def touch_conversation
      message.conversation.touch
    end

    # Broadcasts replacing the tool use partial within its message
    # Uses tool_use_nexrai partial to match what's rendered in message partials
    def broadcast_replace_in_message
      Rails.logger.info("[BROADCAST] ToolUse #{id} (#{name}) replacing, status: #{status}")
      
      broadcast_replace_later_to(
        message.conversation,               # Stream name derived from the conversation
        target: self,                       # Target the tool_use partial itself by DOM ID
        partial: "tool_uses/tool_use_nexrai", # Use the nexrai partial for consistency
        locals: { tool_use: self }
      )
    rescue => e
      Rails.logger.error("Error broadcasting tool use replace: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
  end
end
