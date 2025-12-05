module LlmToolkit
  class ToolUse < ApplicationRecord
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

    # Broadcast changes to the conversation stream
    after_create_commit :broadcast_append_to_message
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

    # Broadcasts appending the tool use partial to its message
    def broadcast_append_to_message
      broadcast_append_later_to(
        message.conversation,               # Stream name derived from the conversation
        target: "tool_uses_for_message_#{message.id}", # Target container within the message partial
        partial: "tool_uses/tool_use",      # The specific tool use partial
        locals: { tool_use: self }
      )
    end

    # Broadcasts replacing the tool use partial within its message
    def broadcast_replace_in_message
      broadcast_replace_later_to(
        message.conversation,               # Stream name derived from the conversation
        target: self,                       # Target the tool_use partial itself by DOM ID
        partial: "tool_uses/tool_use",      # The specific tool use partial
        locals: { tool_use: self }
      )
    end
  end
end
