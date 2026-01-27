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
      
      @openai_model = LlmModel.new(
        name: 'Test OpenAI Model',
        model_id: 'openai/gpt-5.2',
        input_token_limit: 400_000,
        output_token_limit: 128_000
      )
      
      @anthropic_model = LlmModel.new(
        name: 'Test Anthropic Model',
        model_id: 'anthropic/claude-sonnet-4.5',
        input_token_limit: 200_000,
        output_token_limit: 64_000
      )
      
      @system_messages = [{ role: 'system', content: 'You are a helpful assistant.' }]
      @conversation_history = [{ role: 'user', content: 'Hello' }]
    end

    # ===========================================
    # Tests for calculate_max_tokens_for_model
    # ===========================================

    test "Anthropic models return nil (let model decide)" do
      messages = [{ role: 'user', content: 'Hello' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, @anthropic_model, messages)
      
      assert_nil result, "Anthropic models should return nil to let model manage max_tokens"
    end

    test "OpenAI models return calculated max_tokens" do
      messages = [{ role: 'user', content: 'Hello' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, @openai_model, messages)
      
      assert_not_nil result, "OpenAI models should return a max_tokens value"
      assert result > 0, "max_tokens should be positive"
    end

    test "OpenAI models cap max_tokens when context is nearly full" do
      # Create a large message that uses most of the context
      large_content = "x" * 1_500_000  # ~375k tokens estimated (1.5M chars / 4)
      messages = [{ role: 'user', content: large_content }]
      
      result = @provider.send(:calculate_max_tokens_for_model, @openai_model, messages)
      
      # Should be capped below the 128k output_token_limit due to context constraints
      assert result < @openai_model.output_token_limit, 
             "max_tokens should be capped when context is nearly full"
      assert result >= 1000, "Should have at least minimum tokens (1000)"
    end

    test "OpenAI models use output_token_limit when plenty of context space" do
      messages = [{ role: 'user', content: 'Short message' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, @openai_model, messages)
      
      # With a short message, should use the full output_token_limit
      assert_equal @openai_model.output_token_limit, result
    end

    test "uses default_max_tokens when model has no output_token_limit" do
      model_without_limit = LlmModel.new(
        name: 'No Limit Model',
        model_id: 'openai/gpt-test',
        input_token_limit: 100_000,
        output_token_limit: nil
      )
      messages = [{ role: 'user', content: 'Hello' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, model_without_limit, messages)
      
      # Should fall back to default (64000 from config)
      assert_equal LlmToolkit.config.default_max_tokens, result
    end

    test "handles model with no context limit" do
      model_no_context = LlmModel.new(
        name: 'Unknown Context Model',
        model_id: 'openai/gpt-unknown',
        input_token_limit: nil,
        output_token_limit: 32_000
      )
      messages = [{ role: 'user', content: 'Hello' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, model_no_context, messages)
      
      # Should just use the output limit when context limit is unknown
      assert_equal 32_000, result
    end

    # ===========================================
    # Tests for streaming requests
    # ===========================================

    test "stream_openrouter includes max_tokens for OpenAI models" do
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @openai_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/Max output tokens: \d+/, log_content)
      assert_no_match(/not specified/, log_content)
    end

    test "stream_openrouter omits max_tokens for Anthropic models" do
      log_output = StringIO.new
      Rails.logger = Logger.new(log_output)
      
      @provider.stubs(:format_system_messages_for_openrouter).returns([])
      @provider.stubs(:fix_conversation_history_for_openrouter).returns([])
      @provider.stubs(:execute_streaming_request_with_retry).returns({
        'content' => 'Test',
        'model' => 'test',
        'role' => 'assistant'
      })
      
      @provider.send(:stream_openrouter, @anthropic_model, @system_messages, @conversation_history)
      
      log_content = log_output.string
      assert_match(/not specified.*model default/, log_content)
    end

    # ===========================================
    # Tests for edge cases
    # ===========================================

    test "Google models get max_tokens calculated" do
      google_model = LlmModel.new(
        name: 'Test Google Model',
        model_id: 'google/gemini-3-pro',
        input_token_limit: 1_000_000,
        output_token_limit: 64_000
      )
      messages = [{ role: 'user', content: 'Hello' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, google_model, messages)
      
      # Google models should get max_tokens (not Anthropic behavior)
      assert_not_nil result
      assert_equal 64_000, result
    end

    test "Mistral models get max_tokens calculated" do
      mistral_model = LlmModel.new(
        name: 'Test Mistral Model',
        model_id: 'mistralai/devstral',
        input_token_limit: 128_000,
        output_token_limit: 32_000
      )
      messages = [{ role: 'user', content: 'Hello' }]
      
      result = @provider.send(:calculate_max_tokens_for_model, mistral_model, messages)
      
      # Mistral models should get max_tokens (not Anthropic behavior)
      assert_not_nil result
      assert_equal 32_000, result
    end

    test "ensures minimum 1000 tokens even when context is very full" do
      # Model with tiny context
      tiny_model = LlmModel.new(
        name: 'Tiny Model',
        model_id: 'openai/gpt-tiny',
        input_token_limit: 4_000,
        output_token_limit: 4_000
      )
      # Message that exceeds context
      huge_message = "x" * 100_000  # Way over 4k tokens
      messages = [{ role: 'user', content: huge_message }]
      
      result = @provider.send(:calculate_max_tokens_for_model, tiny_model, messages)
      
      # Should still return at least 1000
      assert_equal 1000, result
    end
  end
end
