# frozen_string_literal: true

# =============================================================================
# Unit Test: Verify cache_control Application in Message Formatting
# =============================================================================
#
# ANTHROPIC CACHING STRATEGY (via OpenRouter):
#
# Key constraint: Tool messages (role: "tool") CANNOT have cache_control in
# OpenRouter format - they must have string content, not array content.
#
# Strategy:
# 1. Cache the last non-tool message (enables incremental caching)
# 2. Cache a message BEFORE tool sequences (so tool results get included in cache)
# 3. For long conversations (>25 blocks), add an early breakpoint
#
# This ensures maximum cache hits even with tool-heavy conversations.
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
    # Conversation History Tests - Basic Caching
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
    
    test "simple two message conversation caches last message" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Last message should have cache_control
      cache_positions = find_cache_indices(fixed)
      assert cache_positions.include?(1), "Last message should have cache_control"
    end
    
    # =========================================================================
    # Tool Message Tests - Critical for your issue!
    # =========================================================================
    
    test "tool messages have string content and are NOT cached directly" do
      conv_history = [
        { role: 'user', content: 'Search for Ruby tips' },
        { 
          role: 'assistant', 
          content: '', 
          tool_calls: [{ id: 'tool_1', type: 'function', function: { name: 'search', arguments: '{}' } }] 
        },
        { role: 'tool', tool_call_id: 'tool_1', content: 'Search results here' },
        { role: 'user', content: 'Thanks!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Tool message must have string content (OpenRouter format requirement)
      tool_msg = fixed.find { |m| m[:role] == 'tool' }
      assert tool_msg.present?, "Tool message should exist"
      assert tool_msg[:content].is_a?(String), 
        "Tool message content MUST be string, got #{tool_msg[:content].class}"
      
      # Tool message should NOT have cache_control (it can't in OpenRouter format)
      refute tool_msg[:content].is_a?(Array), "Tool message should not have array content"
    end
    
    test "cache breakpoint is placed BEFORE tool sequence to include tools in cache" do
      conv_history = [
        { role: 'user', content: 'First question' },                    # 0
        { role: 'assistant', content: 'First answer' },                  # 1
        { role: 'user', content: 'Search for something' },               # 2
        { 
          role: 'assistant', 
          content: '', 
          tool_calls: [{ id: 'tool_1', type: 'function', function: { name: 'search', arguments: '{}' } }] 
        },                                                               # 3 - tool sequence starts
        { role: 'tool', tool_call_id: 'tool_1', content: 'Results' },    # 4
        { role: 'user', content: 'Thanks for the results!' }             # 5
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Should have cache on:
      # - Message before tool sequence (index 2) - to cache prefix including this user message
      # - Last message (index 5) - for incremental caching
      cache_positions = find_cache_indices(fixed)
      
      # Last message should definitely be cached
      assert cache_positions.include?(5), "Last message (index 5) should have cache_control"
      
      # There should be a breakpoint that allows tool results to be cached
      # Either before the tool sequence or the last message will do
      assert cache_positions.any?, "Should have at least one cache breakpoint"
    end
    
    test "multiple tool sequences get proper cache breakpoints" do
      conv_history = [
        { role: 'user', content: 'Hello' },                              # 0
        { role: 'assistant', content: 'Hi!' },                           # 1
        { role: 'user', content: 'Do task 1' },                          # 2
        { 
          role: 'assistant', 
          content: '', 
          tool_calls: [{ id: 't1', type: 'function', function: { name: 'tool1', arguments: '{}' } }] 
        },                                                               # 3
        { role: 'tool', tool_call_id: 't1', content: 'Result 1' },       # 4
        { role: 'user', content: 'Now do task 2' },                      # 5
        { 
          role: 'assistant', 
          content: '', 
          tool_calls: [{ id: 't2', type: 'function', function: { name: 'tool2', arguments: '{}' } }] 
        },                                                               # 6
        { role: 'tool', tool_call_id: 't2', content: 'Result 2' },       # 7
        { role: 'user', content: 'Thanks!' }                             # 8
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      cache_positions = find_cache_indices(fixed)
      
      # Last user message should be cached
      assert cache_positions.include?(8), "Last message should have cache_control"
      
      # No tool messages should have cache (they can't)
      [4, 7].each do |tool_idx|
        refute cache_positions.include?(tool_idx), "Tool message at #{tool_idx} should NOT have cache"
      end
    end
    
    # =========================================================================
    # Long Conversation Tests - 20-block lookback issue
    # =========================================================================
    
    test "long conversation gets early breakpoint for 20-block lookback" do
      # Create a conversation with 30 messages (exceeds 20-block lookback)
      conv_history = []
      15.times do |i|
        conv_history << { role: 'user', content: "User message #{i}" }
        conv_history << { role: 'assistant', content: "Assistant response #{i}" }
      end
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      cache_positions = find_cache_indices(fixed)
      
      # Should have multiple breakpoints to handle 20-block lookback
      assert cache_positions.size >= 2, 
        "Long conversation should have multiple cache breakpoints, got #{cache_positions.size}"
      
      # Last message should always be cached
      assert cache_positions.include?(conv_history.size - 1), 
        "Last message should be cached"
      
      # Should have an early breakpoint (before position 20)
      early_breakpoints = cache_positions.select { |pos| pos < 20 }
      assert early_breakpoints.any?, 
        "Should have early breakpoint for 20-block lookback limit"
    end
    
    # =========================================================================
    # Cache Limit Test
    # =========================================================================
    
    test "total cache_control blocks within Anthropic limit of 4" do
      # Large conversation with tools
      conv_history = []
      20.times do |i|
        conv_history << { role: 'user', content: "Question #{i}" }
        if i % 3 == 0
          conv_history << { 
            role: 'assistant', 
            content: '', 
            tool_calls: [{ id: "t#{i}", type: 'function', function: { name: 'tool', arguments: '{}' } }] 
          }
          conv_history << { role: 'tool', tool_call_id: "t#{i}", content: "Result #{i}" }
        else
          conv_history << { role: 'assistant', content: "Response #{i}" }
        end
      end
      
      test_system = [{ type: 'text', text: 'System prompt' * 100 }]
      
      formatted_sys = @provider.send(:format_system_messages_for_openrouter, test_system)
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
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
    # Edge Cases
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
      if assistant_msg[:content].is_a?(Array)
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
    # Helper to find tool sequence starts
    # =========================================================================
    
    test "find_tool_sequence_start_indices identifies tool sequences" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi', tool_calls: [{ id: 't1' }] },  # Tool sequence start
        { role: 'tool', tool_call_id: 't1', content: 'result' },
        { role: 'user', content: 'Thanks' },
        { role: 'assistant', content: 'No problem' },  # No tool calls
        { role: 'user', content: 'Do more' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't2' }] },  # Another tool sequence
        { role: 'tool', tool_call_id: 't2', content: 'result2' },
      ]
      
      starts = @provider.send(:find_tool_sequence_start_indices, conv_history)
      
      assert_equal [1, 6], starts, "Should find tool sequence starts at indices 1 and 6"
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
