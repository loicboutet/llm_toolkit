require 'test_helper'

module LlmToolkit
  class LlmProviderTest < ActiveSupport::TestCase
    test "call should handle nil system_messages" do
      provider = LlmProvider.new(provider_type: 'anthropic', api_key: 'test_key', name: 'Test Provider')
      
      # Stub the API call methods to avoid actual API calls
      provider.stubs(:call_anthropic).returns({})
      
      # Call with nil system_messages
      result = provider.call(nil, [], [])
      
      # This should not raise an error
      assert_equal({}, result)
    end
    
    test "call should handle nil conversation_history" do
      provider = LlmProvider.new(provider_type: 'anthropic', api_key: 'test_key', name: 'Test Provider')
      
      # Stub the API call methods to avoid actual API calls
      provider.stubs(:call_anthropic).returns({})
      
      # Call with nil conversation_history
      result = provider.call([], nil, [])
      
      # This should not raise an error
      assert_equal({}, result)
    end
    
    test "call should handle nil tools" do
      provider = LlmProvider.new(provider_type: 'anthropic', api_key: 'test_key', name: 'Test Provider')
      
      # Stub the API call methods to avoid actual API calls
      provider.stubs(:call_anthropic).returns({})
      
      # Call with nil tools
      result = provider.call([], [], nil)
      
      # This should not raise an error
      assert_equal({}, result)
    end
    
    test "standardize_response should handle nil values" do
      provider = LlmProvider.new(provider_type: 'anthropic', api_key: 'test_key', name: 'Test Provider')
      
      # Call the private method directly (using send for testing purposes)
      result = provider.send(:standardize_response, {
        'content' => nil,
        'model' => 'test-model',
        'role' => 'assistant',
        'stop_reason' => nil,
        'stop_sequence' => nil,
        'usage' => nil
      })
      
      # The method should handle nil values and return a well-formed hash
      assert_equal "", result['content']
      assert_equal [], result['tool_calls']
    end
    
    test "standardize_openrouter_response should handle nil values" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      # Call the private method directly (using send for testing purposes)
      result = provider.send(:standardize_openrouter_response, {
        'choices' => [{
          'message' => {
            'content' => nil,
            'role' => 'assistant',
            'tool_calls' => nil
          },
          'finish_reason' => nil
        }],
        'model' => 'test-model',
        'usage' => nil
      })
      
      # The method should handle nil values and return a well-formed hash
      assert_equal "", result['content']
      assert_equal [], result['tool_calls']
    end
    
    test "format_tools_response_from_openrouter should handle nil tool_calls" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      # Call the private method directly (using send for testing purposes)
      result = provider.send(:format_tools_response_from_openrouter, nil)
      
      # The method should handle nil values and return an empty array
      assert_equal [], result
    end

    # Tests for fix_malformed_json - streaming chunk accumulation bug fix
    test "fix_malformed_json should fix streaming bug pattern with extra brace" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      # The malformed pattern from the streaming bug: {"{command": instead of {"command":
      malformed = '{"{command":"create", "path": "/test", "file_text": "content"}'
      
      result = provider.send(:fix_malformed_json, malformed)
      
      # Should fix to valid JSON
      assert result.start_with?('{"command"'), "Expected to start with {\"command\", got: #{result[0..20]}"
      
      # Should be parseable
      parsed = JSON.parse(result)
      assert_equal "create", parsed["command"]
      assert_equal "/test", parsed["path"]
      assert_equal "content", parsed["file_text"]
    end

    test "fix_malformed_json should not modify valid JSON" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      valid = '{"command":"view", "path": "/test"}'
      
      result = provider.send(:fix_malformed_json, valid)
      
      assert_equal valid, result, "Valid JSON should not be modified"
    end

    test "fix_malformed_json should handle complex file_text with special characters" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      # Simulate a malformed JSON with Ruby code in file_text
      malformed = '{"{command":"create", "path": "/app/model.rb", "file_text": "class User < ApplicationRecord\\n  validates :name, presence: true\\nend"}'
      
      result = provider.send(:fix_malformed_json, malformed)
      
      # Should be parseable
      parsed = JSON.parse(result)
      assert_equal "create", parsed["command"]
      assert parsed["file_text"].include?("class User"), "file_text should contain the Ruby code"
    end

    test "fix_malformed_json should handle missing opening brace" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      # Missing opening brace
      malformed = '"command":"view"}'
      
      result = provider.send(:fix_malformed_json, malformed)
      
      assert result.start_with?('{'), "Should add opening brace"
    end

    test "fix_malformed_json should handle missing closing brace" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      # Missing closing brace
      malformed = '{"command":"view"'
      
      result = provider.send(:fix_malformed_json, malformed)
      
      assert result.end_with?('}'), "Should add closing brace"
    end

    test "fix_malformed_json should handle empty string" do
      provider = LlmProvider.new(provider_type: 'openrouter', api_key: 'test_key', name: 'Test Provider')
      
      result = provider.send(:fix_malformed_json, '')
      
      assert_equal '{}', result, "Empty string should become empty JSON object"
    end
  end
end