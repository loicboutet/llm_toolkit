module LlmToolkit
  # Custom error raised when a conversation is cancelled
  class CancellationError < StandardError
    attr_reader :conversation_id
    
    def initialize(message = "Conversation was cancelled", conversation_id: nil)
      @conversation_id = conversation_id
      super(message)
    end
  end
  
  module CancellationCheck
    extend ActiveSupport::Concern

    # Wrap a block with cancellation checks before and after
    # @param conversation [Conversation] The conversation to check
    # @yield The block to execute
    # @return The result of the block
    # @raise [CancellationError] if conversation was cancelled
    def with_cancellation_check(conversation)
      check_cancellation!(conversation)
      result = yield
      check_cancellation!(conversation)
      result
    end

    # Check if a conversation has been cancelled and raise if so
    # @param conversation [Conversation] The conversation to check
    # @raise [CancellationError] if conversation was cancelled
    def check_cancellation!(conversation)
      return unless conversation
      
      # Reload to get fresh state from database
      conversation.reload
      
      if conversation.canceled?
        raise CancellationError.new(
          "Conversation #{conversation.id} was cancelled",
          conversation_id: conversation.id
        )
      end
    end
    
    # Check cancellation every N calls (for performance in tight loops)
    # @param n [Integer] Check every N calls
    # @param counter [Integer] Current counter value
    # @param conversation [Conversation] The conversation to check
    # @raise [CancellationError] if conversation was cancelled
    def check_cancellation_every!(n, counter, conversation)
      return unless (counter % n).zero?
      check_cancellation!(conversation)
    end
  end
end
