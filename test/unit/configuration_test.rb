# frozen_string_literal: true

require "test_helper"

module LlmToolkit
  class ConfigurationTest < ActiveSupport::TestCase
    setup do
      @original_config = LlmToolkit.config.dup
    end
    
    teardown do
      # Restore original config
      LlmToolkit.instance_variable_set(:@config, @original_config)
    end

    test "configuration has default values" do
      config = Configuration.new
      
      assert_equal [], config.dangerous_tools
      assert_equal "claude-3-7-sonnet-20250219", config.default_anthropic_model
      assert_equal "anthropic/claude-3-sonnet", config.default_openrouter_model
      assert_equal 8192, config.default_max_tokens
      assert_equal "http://localhost:3000", config.referer_url
      assert_equal true, config.enable_prompt_caching
      assert_equal 2048, config.cache_text_threshold
      assert_equal 50, config.streaming_throttle_ms
      assert_equal 100, config.max_tool_followups
      assert_equal 50_000, config.max_tool_result_size
      assert_kind_of Array, config.placeholder_markers
      assert config.placeholder_markers.frozen?
    end

    test "configuration values can be customized" do
      LlmToolkit.configure do |config|
        config.dangerous_tools = ['write_to_file', 'delete_record']
        config.streaming_throttle_ms = 100
        config.max_tool_followups = 50
        config.max_tool_result_size = 25_000
      end
      
      assert_equal ['write_to_file', 'delete_record'], LlmToolkit.config.dangerous_tools
      assert_equal 100, LlmToolkit.config.streaming_throttle_ms
      assert_equal 50, LlmToolkit.config.max_tool_followups
      assert_equal 25_000, LlmToolkit.config.max_tool_result_size
    end

    test "placeholder_content? returns true for blank content" do
      config = Configuration.new
      
      assert config.placeholder_content?(nil)
      assert config.placeholder_content?("")
      assert config.placeholder_content?("   ")
    end

    test "placeholder_content? returns true for placeholder markers" do
      config = Configuration.new
      
      config.placeholder_markers.each do |marker|
        assert config.placeholder_content?(marker), "Should detect placeholder: #{marker}"
        assert config.placeholder_content?("  #{marker}  "), "Should detect placeholder with whitespace: #{marker}"
      end
    end

    test "placeholder_content? returns false for real content" do
      config = Configuration.new
      
      refute config.placeholder_content?("Hello, how can I help you?")
      refute config.placeholder_content?("This is a real response from the LLM.")
      refute config.placeholder_content?("🤔 Some other emoji message")
    end

    test "placeholder_markers can be customized" do
      config = Configuration.new
      config.placeholder_markers = ["Loading...", "Please wait..."].freeze
      
      assert config.placeholder_content?("Loading...")
      assert config.placeholder_content?("Please wait...")
      refute config.placeholder_content?("🤔 Traitement de votre demande...")
    end

    test "streaming_throttle_ms is used for broadcast throttling" do
      # This test verifies the config value is accessible
      assert_equal 50, LlmToolkit.config.streaming_throttle_ms
      
      # Update and verify
      LlmToolkit.config.streaming_throttle_ms = 75
      assert_equal 75, LlmToolkit.config.streaming_throttle_ms
    end

    test "max_tool_followups provides safety limit" do
      assert_equal 100, LlmToolkit.config.max_tool_followups
      
      # Should be configurable
      LlmToolkit.config.max_tool_followups = 200
      assert_equal 200, LlmToolkit.config.max_tool_followups
    end

    test "max_tool_result_size controls truncation threshold" do
      assert_equal 50_000, LlmToolkit.config.max_tool_result_size
      
      # Verify it can be changed
      LlmToolkit.config.max_tool_result_size = 100_000
      assert_equal 100_000, LlmToolkit.config.max_tool_result_size
    end
  end
end
