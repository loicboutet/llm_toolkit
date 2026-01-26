# frozen_string_literal: true

require 'test_helper'

module LlmToolkit
  class OpenrouterMaxTokensTest < ActiveSupport::TestCase
    setup do
      @provider = LlmProvider.new(
        provider_type: 'openrouter',
        api_key: 'test_key',
        name: 'Test OpenRouter Provider'
      )
      
      @llm_model = LlmModel.new(
        name: 'Test Model',
        model_id: 'openai/gpt-5.2',
        input_token_limit: 400_000,
        output_token_limit: nil
      )
      
      @system_messages = [{ role: 'system', content: 'You are a helpful assistant.' }]
      @conversation_history = [{ role: 'user', content: 'Hello' }]
    end

    # ===========================================
    # Tests for max_tokens in streaming requests
    # ===========================================

    test "stream_openrouter uses model output_token_limit when set" do
      @llm_model.output_token_limit = 128_000
      
      # We'll test by checking the log output
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/Max output tokens: 128000/, log_content)
    end

    test "stream_openrouter uses settings max_tokens when model limit not set" do
      @llm_model.output_token_limit = nil
      @provider.settings = { 'max_tokens' => 64_000 }
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/Max output tokens: 64000/, log_content)
    end

    test "stream_openrouter uses default max_tokens when nothing else set" do
      @llm_model.output_token_limit = nil
      @provider.settings = nil
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      # Default is 8192 from configuration
      assert_match(/Max output tokens: 8192/, log_content)
    end

    test "stream_openrouter prioritizes model limit over settings" do
      @llm_model.output_token_limit = 128_000
      @provider.settings = { 'max_tokens' => 32_000 }
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      # Model limit (128000) should take priority over settings (32000)
      assert_match(/Max output tokens: 128000/, log_content)
    end

    # ===========================================
    # Tests for max_tokens in non-streaming requests
    # ===========================================

    test "call_openrouter should include max_tokens in request body" do
      @llm_model.output_token_limit = 128_000
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      # Mock Faraday
      mock_client = mock('faraday_client')
      mock_response = mock('response')
      mock_response.stubs(:success?).returns(true)
      mock_response.stubs(:body).returns({
        'choices' => [{
          'message' => { 'content' => 'Test', 'role' => 'assistant' },
          'finish_reason' => 'stop'
        }],
        'model' => 'openai/gpt-5.2',
        'usage' => { 'prompt_tokens' => 100, 'completion_tokens' => 50 }
      })
      
      Faraday.stubs(:new).returns(mock_client)
      mock_client.stubs(:post).returns(mock_response)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      
      @provider.send(:call_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/Max output tokens: 128000/, log_content)
    end

    test "call_openrouter uses settings when model limit not set" do
      @llm_model.output_token_limit = nil
      @provider.settings = { 'max_tokens' => 50_000 }
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      mock_client = mock('faraday_client')
      mock_response = mock('response')
      mock_response.stubs(:success?).returns(true)
      mock_response.stubs(:body).returns({
        'choices' => [{
          'message' => { 'content' => 'Test', 'role' => 'assistant' },
          'finish_reason' => 'stop'
        }],
        'model' => 'test',
        'usage' => {}
      })
      
      Faraday.stubs(:new).returns(mock_client)
      mock_client.stubs(:post).returns(mock_response)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      
      @provider.send(:call_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/Max output tokens: 50000/, log_content)
    end

    # ===========================================
    # Tests for edge cases
    # ===========================================

    test "handles output_token_limit of 0 by falling back to settings" do
      @llm_model.output_token_limit = 0
      @provider.settings = { 'max_tokens' => 16_000 }
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      # 0 is falsy with .presence, so should fall back to settings
      assert_match(/Max output tokens: 16000/, log_content)
    end

    test "handles string max_tokens in settings" do
      @llm_model.output_token_limit = nil
      @provider.settings = { 'max_tokens' => '32000' }  # String instead of integer
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/Max output tokens: 32000/, log_content)
    end

    test "handles nil settings gracefully" do
      @llm_model.output_token_limit = nil
      @provider.settings = nil
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      # Should not raise and should use default
      assert_nothing_raised do
        @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      end
      
      log_content = log_output.string
      assert_match(/Max output tokens: 8192/, log_content)
    end

    test "handles empty settings hash gracefully" do
      @llm_model.output_token_limit = nil
      @provider.settings = {}
      
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      assert_nothing_raised do
        @provider.send(:stream_openrouter, @llm_model, @system_messages, @conversation_history)
      end
      
      log_content = log_output.string
      assert_match(/Max output tokens: 8192/, log_content)
    end
  end
end
