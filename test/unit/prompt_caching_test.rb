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
# For effective multi-turn caching, Anthropic recommends caching the LAST 2 MESSAGES:
# - This enables incremental caching across conversation turns
# - The cache system looks for matching prefixes up to cache breakpoints
# - With 2 breakpoints in conversation + 1 in system = 3 total (within Anthropic's 4 limit)
#
# Example flow:
# Request 1: [System<cache>] + [User1<cache>]
# Request 2: [System<cache>] + [User1] + [Asst1<cache>] + [User2<cache>]
# Request 3: [System<cache>] + [User1] + [Asst1] + [User2<cache>] + [Asst2<cache>] + [User3<cache>]
#            ^ On Request 3, "System + User1 + Asst1" can match cache from Request 2
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
    
    test "two message conversation has cache_control on both messages" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Both messages should have cache_control (last 2)
      cache_positions = find_cache_indices(fixed)
      assert_equal [0, 1], cache_positions.sort, "Both messages should have cache_control"
    end
    
    test "multi-turn conversation has cache_control on last 2 messages" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' },
        { role: 'user', content: 'How are you?' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Only the LAST 2 messages should have cache_control
      # Message 0 should NOT have cache_control
      msg0 = fixed[0]
      has_cache0 = msg0[:content].is_a?(Array) && msg0[:content].any? { |c| c[:cache_control].present? }
      refute has_cache0, "Message at index 0 should NOT have cache_control"
      
      # Messages 1 and 2 should have cache_control
      [1, 2].each do |idx|
        msg = fixed[idx]
        assert msg[:content].is_a?(Array), "Message #{idx} should have array content"
        assert msg[:content].any? { |c| c[:cache_control].present? }, 
          "Message at index #{idx} should have cache_control"
      end
    end
    
    test "5 message conversation has cache_control on last 2 messages" do
      conv_history = [
        { role: 'user', content: 'First message' },
        { role: 'assistant', content: 'First response' },
        { role: 'user', content: 'Second message' },
        { role: 'assistant', content: 'Second response' },
        { role: 'user', content: 'Third message' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Only messages 3 and 4 (last 2) should have cache_control
      cache_positions = find_cache_indices(fixed)
      assert_equal [3, 4], cache_positions.sort, "Only the last 2 messages should have cache_control"
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
    
    test "tool messages have string content and are skipped for caching" do
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
      
      # Last 2 non-tool messages should have cache_control
      # Non-tool messages are at indices 0, 1, 3 (tool is at index 2)
      # Last 2 non-tool indices are 1 and 3
      
      # Index 0 (first user) should NOT have cache_control
      msg0 = fixed[0]
      has_cache0 = msg0[:content].is_a?(Array) && msg0[:content].any? { |c| c[:cache_control].present? }
      refute has_cache0, "First user message should NOT have cache_control"
      
      # Index 1 (assistant with tool_calls) should have cache_control
      msg1 = fixed[1]
      has_cache1 = msg1[:content].is_a?(Array) && msg1[:content].any? { |c| c[:cache_control].present? }
      assert has_cache1, "Assistant message (second-to-last non-tool) should have cache_control"
      
      # Index 3 (last user) should have cache_control
      msg3 = fixed[3]
      assert msg3[:content].is_a?(Array), "Last user message should have array content"
      assert msg3[:content].any? { |c| c[:cache_control].present? },
        "Last user message should have cache_control"
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
      # Since the assistant message is one of the last 2, it might be converted to array
      # But if content was nil, it should be empty string ""
      if assistant_msg[:content].is_a?(Array)
        # If converted to array, it should have empty text
        text_content = assistant_msg[:content].find { |c| c[:type] == 'text' }
        assert text_content.nil? || text_content[:text].to_s.empty?, 
          "nil content should result in empty content"
      else
        assert_equal "", assistant_msg[:content], 
          "nil content should be converted to empty string"
      end
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
      # 1 for system + 2 for last 2 conversation messages = 3 total
      assert_equal 3, total_cache_controls,
        "Expected exactly 3 cache_control blocks (1 system, 2 conversation)"
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
    
    # =========================================================================
    # Test the find_cache_breakpoint_indices helper
    # =========================================================================
    
    test "find_cache_breakpoint_indices returns last 2 non-tool message indices" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi' },
        { role: 'tool', tool_call_id: 'x', content: 'result' },
        { role: 'user', content: 'Thanks' }
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, conv_history)
      
      # Non-tool indices are 0, 1, 3
      # Last 2 are 1 and 3
      assert_equal [1, 3], indices.sort
    end
    
    test "find_cache_breakpoint_indices returns single index for single message" do
      conv_history = [
        { role: 'user', content: 'Hello' }
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, conv_history)
      
      assert_equal [0], indices
    end
    
    test "find_cache_breakpoint_indices returns empty for empty history" do
      indices = @provider.send(:find_cache_breakpoint_indices, [])
      
      assert_equal [], indices
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
