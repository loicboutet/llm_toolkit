# frozen_string_literal: true

require "test_helper"

module LlmToolkit
  class UserIdPropagationTest < ActiveSupport::TestCase
    # Test that user_id is properly propagated through the conversation and service chain
    # This tests the Thread.current[:current_user_id] pattern usage
    
    setup do
      # Clear any previous Thread.current state
      Thread.current[:current_user_id] = nil
    end
    
    teardown do
      Thread.current[:current_user_id] = nil
    end

    test "CallLlmWithToolService uses explicit user_id when provided" do
      # Mock the necessary objects
      mock_provider = mock_llm_provider
      mock_model = mock_llm_model(mock_provider)
      mock_conversation = mock_conversation_for_service
      
      # Set Thread.current to a different value to ensure explicit takes precedence
      Thread.current[:current_user_id] = 999
      
      service = CallLlmWithToolService.new(
        llm_model: mock_model,
        conversation: mock_conversation,
        tool_classes: [],
        user_id: 42  # Explicit user_id
      )
      
      assert_equal 42, service.user_id, "Service should use explicit user_id over Thread.current"
    end

    test "CallLlmWithToolService falls back to Thread.current when user_id not provided" do
      mock_provider = mock_llm_provider
      mock_model = mock_llm_model(mock_provider)
      mock_conversation = mock_conversation_for_service
      
      Thread.current[:current_user_id] = 123
      
      service = CallLlmWithToolService.new(
        llm_model: mock_model,
        conversation: mock_conversation,
        tool_classes: []
        # No explicit user_id
      )
      
      assert_equal 123, service.user_id, "Service should fall back to Thread.current[:current_user_id]"
    end

    test "CallLlmWithToolService handles nil user_id gracefully" do
      mock_provider = mock_llm_provider
      mock_model = mock_llm_model(mock_provider)
      mock_conversation = mock_conversation_for_service
      
      Thread.current[:current_user_id] = nil
      
      service = CallLlmWithToolService.new(
        llm_model: mock_model,
        conversation: mock_conversation,
        tool_classes: []
      )
      
      assert_nil service.user_id, "Service should handle nil user_id gracefully"
    end

    test "Thread.current isolation between threads" do
      Thread.current[:current_user_id] = 100
      
      thread_user_id = nil
      new_thread = Thread.new do
        thread_user_id = Thread.current[:current_user_id]
      end
      new_thread.join
      
      assert_equal 100, Thread.current[:current_user_id], "Main thread should retain its value"
      assert_nil thread_user_id, "New thread should not inherit Thread.current values"
    end

    test "CallStreamingLlmWithToolService uses explicit user_id" do
      mock_provider = mock_llm_provider('openrouter')
      mock_model = mock_llm_model(mock_provider)
      mock_conversation = mock_conversation_for_service
      mock_message = mock_assistant_message
      
      Thread.current[:current_user_id] = 999
      
      service = CallStreamingLlmWithToolService.new(
        llm_model: mock_model,
        conversation: mock_conversation,
        assistant_message: mock_message,
        tool_classes: [],
        user_id: 55
      )
      
      assert_equal 55, service.user_id, "Streaming service should use explicit user_id"
    end

    private

    def mock_llm_provider(provider_type = 'anthropic')
      provider = Minitest::Mock.new
      provider.expect(:provider_type, provider_type)
      provider
    end

    def mock_llm_model(provider)
      model = Minitest::Mock.new
      model.expect(:llm_provider, provider)
      model
    end

    def mock_conversation_for_service
      conversation = Minitest::Mock.new
      conversable = Minitest::Mock.new
      conversable.expect(:respond_to?, false, [:generate_system_messages])
      conversation.expect(:conversable, conversable)
      conversation.expect(:agent_type, 'planner')
      conversation
    end

    def mock_assistant_message
      message = Minitest::Mock.new
      message.expect(:content, "")
      message.expect(:id, 1)
      message
    end
  end
end
