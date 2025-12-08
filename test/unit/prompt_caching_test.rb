# frozen_string_literal: true

# =============================================================================
# Unit Test: Verify cache_control Application in Message Formatting
# =============================================================================
#
# ANTHROPIC CACHING STRATEGY (via OpenRouter):
#
# From the Anthropic docs:
# "During each turn, we mark the final block of the final message with cache_control
# so the conversation can be incrementally cached."
#
# How it works:
# - cache_control marks the END of a cacheable prefix
# - The system automatically looks back up to 20 blocks for cache hits
# - We place cache_control on the LAST message to enable incremental caching
#
# Example flow:
# Request 1: [System<cache>] + [User: "Hello"<cache>]
# Request 2: [System<cache>] + [User: "Hello"] + [Assistant: "Hi!"] + [User: "How are you?"<cache>]
# Request 3: [System<cache>] + [...history...] + [User: "What's 2+2?"<cache>]
#
# Run with: bin/rails test llm_toolkit/test/unit/prompt_caching_test.rb
#
# =============================================================================

require "test_helper"

module LlmToolkit
  class PromptCachingTest < ActiveSupport::TestCase
    setup do
      @original_caching = LlmToolkit.config.enable_prompt_caching
      LlmToolkit.config.enable_prompt_caching = true
      
      @provider = LlmToolkit::LlmProvider.new(
        name: 'Test Provider',
        api_key: 'test-key',
        provider_type: 'openrouter'
      )
    end
    
    teardown do
      LlmToolkit.config.enable_prompt_caching = @original_caching
    end
    
    # =========================================================================
    # System Message Tests
    # =========================================================================
    
    test "simple system message gets cache_control" do
      simple_system = ["You are a helpful assistant."]
      formatted = @provider.send(:format_system_messages_for_openrouter, simple_system)
      
      assert formatted.any? { |msg|
        msg[:content].is_a?(Array) && 
        msg[:content].any? { |c| c[:cache_control].present? }
      }, "Simple system message should have cache_control"
    end
    
    test "complex system message has cache_control only on last text block" do
      complex_system = [
        {
          role: 'system',
          content: [
            { type: 'text', text: 'First block' },
            { type: 'text', text: 'Second block' },
            { type: 'text', text: 'Third block' }
          ]
        }
      ]
      formatted = @provider.send(:format_system_messages_for_openrouter, complex_system)
      
      cache_positions = []
      formatted.each_with_index do |msg, msg_idx|
        next unless msg[:content].is_a?(Array)
        msg[:content].each_with_index do |content, content_idx|
          cache_positions << [msg_idx, content_idx] if content[:cache_control].present?
        end
      end
      
      assert_equal 1, cache_positions.length, "Should have exactly 1 cache_control block"
      assert_equal [0, 2], cache_positions.first, "cache_control should be on last (index 2) text block"
    end
    
    # =========================================================================
    # Conversation History Tests - Incremental Caching
    # =========================================================================
    
    test "single message gets cache_control on that message" do
      conv_history = [
        { role: 'user', content: 'Hello' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # The last (and only) message should have cache_control
      last_msg = fixed[0]
      assert last_msg[:content].is_a?(Array), "Message content should be array"
      assert last_msg[:content].any? { |c| c[:cache_control].present? }, 
        "Last message should have cache_control"
    end
    
    test "multi-turn conversation has cache_control on last message only" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' },
        { role: 'user', content: 'How are you?' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Only the LAST message should have cache_control
      # Messages 0 and 1 should NOT have cache_control
      [0, 1].each do |idx|
        msg = fixed[idx]
        has_cache = msg[:content].is_a?(Array) && msg[:content].any? { |c| c[:cache_control].present? }
        refute has_cache, "Message at index #{idx} should NOT have cache_control"
      end
      
      # Message 2 (last) should have cache_control
      last_msg = fixed[2]
      assert last_msg[:content].is_a?(Array), "Last message should have array content"
      assert last_msg[:content].any? { |c| c[:cache_control].present? }, 
        "Last message should have cache_control"
    end
    
    test "5 message conversation has cache_control on last message" do
      conv_history = [
        { role: 'user', content: 'First message' },
        { role: 'assistant', content: 'First response' },
        { role: 'user', content: 'Second message' },
        { role: 'assistant', content: 'Second response' },
        { role: 'user', content: 'Third message' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Only message 4 (last) should have cache_control
      cache_positions = find_cache_indices(fixed)
      assert_equal [4], cache_positions, "Only the last message should have cache_control"
    end
    
    test "multimodal user message with image gets cache_control on last text block" do
      conv_history = [
        { 
          role: 'user', 
          content: [
            { type: 'text', text: 'What is in this image?' },
            { type: 'image_url', image_url: { url: 'data:image/png;base64,abc123' } }
          ]
        }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Content should remain as array
      assert fixed[0][:content].is_a?(Array), "Content should remain as array"
      
      # Image should be preserved
      image_item = fixed[0][:content].find { |c| c[:type] == 'image_url' }
      assert image_item.present?, "Image item should be preserved"
      
      # Text block should have cache_control (it's the last text block)
      text_item = fixed[0][:content].find { |c| c[:type] == 'text' }
      assert text_item[:cache_control].present?, "Text block should have cache_control"
    end
    
    test "tool messages have string content and are not cached" do
      conv_history = [
        { role: 'user', content: 'Search for Ruby tips' },
        { 
          role: 'assistant', 
          content: nil, 
          tool_calls: [{ id: 'tool_1', type: 'function', function: { name: 'search', arguments: '{}' } }] 
        },
        { role: 'tool', tool_call_id: 'tool_1', content: 'Search results here' },
        { role: 'user', content: 'Thanks!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Tool message must have string content
      tool_msg = fixed.find { |m| m[:role] == 'tool' }
      assert tool_msg.present?, "Tool message should exist"
      assert tool_msg[:content].is_a?(String), 
        "Tool message content MUST be string, got #{tool_msg[:content].class}"
      
      # Last user message (index 3) should have cache_control
      last_msg = fixed[3]
      assert last_msg[:content].is_a?(Array), "Last message should have array content"
      assert last_msg[:content].any? { |c| c[:cache_control].present? },
        "Last message should have cache_control"
    end
    
    # =========================================================================
    # Edge Case Tests
    # =========================================================================
    
    test "nil content converted to empty string" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: nil },
        { role: 'user', content: 'Continue' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # nil content should become empty string
      assistant_msg = fixed[1]
      assert_equal "", assistant_msg[:content], 
        "nil content should be converted to empty string"
    end
    
    test "tool message with array content is converted to string" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { 
          role: 'tool', 
          tool_call_id: 'tool_1', 
          content: [
            { type: 'text', text: 'Result line 1' },
            { type: 'text', text: 'Result line 2' }
          ] 
        }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      tool_msg = fixed.find { |m| m[:role] == 'tool' }
      assert tool_msg[:content].is_a?(String), "Tool message content should be converted to string"
      assert tool_msg[:content].include?('Result line 1'), "Should contain first line"
      assert tool_msg[:content].include?('Result line 2'), "Should contain second line"
    end
    
    # =========================================================================
    # Cache Limit Test
    # =========================================================================
    
    test "total cache_control blocks within Anthropic limit of 4" do
      test_system = [{ type: 'text', text: 'System prompt' * 100 }]
      test_history = [
        { role: 'user', content: 'User message 1' },
        { role: 'assistant', content: 'Assistant response' },
        { role: 'user', content: 'User message 2' },
        { role: 'assistant', content: 'Assistant response 2' },
        { role: 'user', content: 'User message 3' }
      ]
      
      formatted_sys = @provider.send(:format_system_messages_for_openrouter, test_system)
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, test_history)
      
      total_cache_controls = 0
      
      formatted_sys.each do |msg|
        next unless msg[:content].is_a?(Array)
        msg[:content].each { |c| total_cache_controls += 1 if c[:cache_control].present? }
      end
      
      fixed_hist.each do |msg|
        next unless msg[:content].is_a?(Array)
        msg[:content].each { |c| total_cache_controls += 1 if c[:cache_control].present? }
      end
      
      assert total_cache_controls <= 4, 
        "Should use at most 4 cache_control blocks, using #{total_cache_controls}"
      assert_equal 2, total_cache_controls,
        "Expected exactly 2 cache_control blocks (1 system, 1 conversation)"
    end
    
    # =========================================================================
    # Caching Disabled Test
    # =========================================================================
    
    test "no cache_control when caching disabled" do
      LlmToolkit.config.enable_prompt_caching = false
      
      test_system = [{ type: 'text', text: 'System prompt' }]
      test_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi!' },
        { role: 'user', content: 'Bye' }
      ]
      
      formatted_sys = @provider.send(:format_system_messages_for_openrouter, test_system)
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, test_history)
      
      sys_cache_count = formatted_sys.sum do |msg|
        next 0 unless msg[:content].is_a?(Array)
        msg[:content].count { |c| c[:cache_control].present? }
      end
      
      hist_cache_count = fixed_hist.sum do |msg|
        next 0 unless msg[:content].is_a?(Array)
        msg[:content].count { |c| c[:cache_control].present? }
      end
      
      assert_equal 0, sys_cache_count, "No cache_control when disabled (system)"
      assert_equal 0, hist_cache_count, "No cache_control when disabled (history)"
    end
    
    # =========================================================================
    # String Key Tests
    # =========================================================================
    
    test "handles string keys from conversation history" do
      conv_history = [
        { 
          role: 'user', 
          content: [
            { 'type' => 'text', 'text' => 'Hello with string keys' }
          ]
        }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      assert fixed[0][:content].is_a?(Array), "Content should be array"
      
      has_cache = fixed[0][:content].any? do |item|
        item[:cache_control].present? || item['cache_control'].present?
      end
      
      assert has_cache, "Should have cache_control on last message"
    end
    
    private
    
    def find_cache_indices(fixed_history)
      indices = []
      fixed_history.each_with_index do |msg, idx|
        if msg[:content].is_a?(Array) && msg[:content].any? { |c| c[:cache_control].present? }
          indices << idx
        end
      end
      indices
    end
  end
end
