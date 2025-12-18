#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone test for Configuration - doesn't require Rails environment
# Run with: ruby test/unit/configuration_standalone_test.rb

require 'minitest/autorun'

# Load just the configuration module
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'llm_toolkit/configuration'

module LlmToolkit
  # Mock the config accessor for testing
  def self.config
    @@config ||= Configuration.new
  end
  
  def self.configure
    @@config ||= Configuration.new
    yield @@config
  end
end

class ConfigurationStandaloneTest < Minitest::Test
  def setup
    @config = LlmToolkit::Configuration.new
  end

  def test_default_values
    assert_equal [], @config.dangerous_tools
    assert_equal "claude-3-7-sonnet-20250219", @config.default_anthropic_model
    assert_equal "anthropic/claude-3-sonnet", @config.default_openrouter_model
    assert_equal 8192, @config.default_max_tokens
    assert_equal "http://localhost:3000", @config.referer_url
    assert_equal true, @config.enable_prompt_caching
    assert_equal 2048, @config.cache_text_threshold
    assert_equal 50, @config.streaming_throttle_ms
    assert_equal 100, @config.max_tool_followups
    assert_equal 50_000, @config.max_tool_result_size
  end

  def test_placeholder_markers_are_frozen
    assert @config.placeholder_markers.frozen?
  end

  def test_placeholder_markers_contain_expected_values
    assert_includes @config.placeholder_markers, "🤔 Traitement de votre demande..."
    assert_includes @config.placeholder_markers, "🎯 Analyse automatique en cours..."
  end

  def test_placeholder_content_detects_blank
    assert @config.placeholder_content?(nil)
    assert @config.placeholder_content?("")
    assert @config.placeholder_content?("   ")
  end

  def test_placeholder_content_detects_markers
    @config.placeholder_markers.each do |marker|
      assert @config.placeholder_content?(marker), "Should detect placeholder: #{marker}"
    end
  end

  def test_placeholder_content_detects_markers_with_whitespace
    @config.placeholder_markers.each do |marker|
      assert @config.placeholder_content?("  #{marker}  "), "Should detect with whitespace: #{marker}"
    end
  end

  def test_placeholder_content_rejects_real_content
    refute @config.placeholder_content?("Hello, how can I help you?")
    refute @config.placeholder_content?("This is a real response from the LLM.")
    refute @config.placeholder_content?("🤔 Some other emoji message that's different")
  end

  def test_configuration_values_are_writable
    @config.streaming_throttle_ms = 100
    assert_equal 100, @config.streaming_throttle_ms
    
    @config.max_tool_followups = 50
    assert_equal 50, @config.max_tool_followups
    
    @config.max_tool_result_size = 25_000
    assert_equal 25_000, @config.max_tool_result_size
  end

  def test_dangerous_tools_can_be_set
    @config.dangerous_tools = ['write_to_file', 'delete_record']
    assert_equal ['write_to_file', 'delete_record'], @config.dangerous_tools
  end

  def test_custom_placeholder_markers
    @config.placeholder_markers = ["Loading...", "Please wait..."].freeze
    
    assert @config.placeholder_content?("Loading...")
    assert @config.placeholder_content?("Please wait...")
    refute @config.placeholder_content?("🤔 Traitement de votre demande...")
  end

  def test_configure_block
    LlmToolkit.configure do |config|
      config.dangerous_tools = ['test_tool']
      config.streaming_throttle_ms = 75
    end
    
    assert_equal ['test_tool'], LlmToolkit.config.dangerous_tools
    assert_equal 75, LlmToolkit.config.streaming_throttle_ms
  end
end
