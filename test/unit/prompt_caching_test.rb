# frozen_string_literal: true

# =============================================================================
# Unit Test: Verify cache_control Application in Message Formatting
# =============================================================================
#
# ANTHROPIC CACHING STRATEGY (via OpenRouter):
#
# Key findings from real-world testing:
# 1. Tool messages CAN have array content with cache_control!
# 2. Empty messages (content: '') cache NOTHING useful
# 3. Minimum ~1024 tokens required for caching to activate
#
# Strategy:
# 1. Cache the first user message (stable anchor)
# 2. Cache the last tool message with content (largest data usually!)
# 3. Cache the last non-tool message with content (fallback)
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
    # Basic Caching Tests
    # =========================================================================
    
    test "single user message gets cache_control" do
      conv_history = [
        { role: 'user', content: 'Hello world!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      assert fixed[0][:content].is_a?(Array), "Message content should be array"
      assert fixed[0][:content].any? { |c| c[:cache_control].present? }, 
        "Single message should have cache_control"
    end
    
    test "two message conversation caches first user and last with content" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      cache_positions = find_cache_indices(fixed)
      
      assert cache_positions.include?(0), "First user message should be cached"
      assert cache_positions.include?(1), "Last message with content should be cached"
    end
    
    # =========================================================================
    # Tool Message Caching - NEW! Tool messages can be cached!
    # =========================================================================
    
    test "tool messages CAN have array content with cache_control" do
      conv_history = [
        { role: 'user', content: 'Search for Ruby tips' },
        { 
          role: 'assistant', 
          content: 'Let me search for that.', 
          tool_calls: [{ id: 'tool_1', type: 'function', function: { name: 'search', arguments: '{}' } }] 
        },
        { role: 'tool', tool_call_id: 'tool_1', content: 'Search results here with lots of content' },
        { role: 'user', content: 'Thanks!' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Tool message at index 2 should be cached (last tool with content)
      tool_msg = fixed[2]
      assert tool_msg.present?, "Tool message should exist"
      
      # Tool message should have array content with cache_control
      assert tool_msg[:content].is_a?(Array), 
        "Cached tool message should have array content"
      assert tool_msg[:content].any? { |c| c[:cache_control].present? },
        "Cached tool message should have cache_control"
    end
    
    test "last tool message with content is cached" do
      conv_history = [
        { role: 'user', content: 'Help me' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't1' }] },
        { role: 'tool', tool_call_id: 't1', content: 'First result' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't2' }] },
        { role: 'tool', tool_call_id: 't2', content: 'Second result - larger' },  # LAST tool
        { role: 'assistant', content: 'Analysis complete.' },
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      cache_positions = find_cache_indices(fixed)
      
      # Should cache: first user (0), last tool (4), last with content (5)
      assert cache_positions.include?(0), "First user should be cached"
      assert cache_positions.include?(4), "Last tool message should be cached"
      assert cache_positions.include?(5), "Last assistant with content should be cached"
    end
    
    # =========================================================================
    # Empty Message Tests - CRITICAL: Empty messages should NOT be cached
    # =========================================================================
    
    test "caching is position-based: first user, second-to-last, and last" do
      conv_history = [
        { role: 'user', content: 'List all files' },
        { 
          role: 'assistant', 
          content: '',  # Empty but still cached if in position
          tool_calls: [{ id: 'tool_1', type: 'function', function: { name: 'list', arguments: '{}' } }] 
        },
        { role: 'tool', tool_call_id: 'tool_1', content: 'file1.rb, file2.rb' }
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, conv_history)
      
      # Position-based caching: first user (0), second-to-last (1), last (2)
      assert indices.include?(0), "First user message should be cached"
      assert indices.include?(1), "Second-to-last message should be cached (position-based)"
      assert indices.include?(2), "Last message should be cached"
    end
    
    test "position-based caching with multiple messages" do
      conv_history = [
        { role: 'user', content: 'Help me review files' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't1' }] },
        { role: 'tool', tool_call_id: 't1', content: 'File 1 content' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't2' }] },
        { role: 'tool', tool_call_id: 't2', content: 'File 2 content' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't3' }] },
        { role: 'tool', tool_call_id: 't3', content: 'File 3 content' },  # Last (index 6)
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, conv_history)
      
      # Position-based: first user (0), second-to-last (5), last (6)
      assert indices.include?(0), "First user should be cached"
      assert indices.include?(5), "Second-to-last (index 5) should be cached"
      assert indices.include?(6), "Last (index 6) should be cached"
    end
    
    # =========================================================================
    # Cache Breakpoint Index Tests
    # =========================================================================
    
    test "find_cache_breakpoint_indices includes tool messages" do
      messages = [
        { role: 'user', content: 'Start' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't1' }] },
        { role: 'tool', tool_call_id: 't1', content: 'Large tool result here' },
        { role: 'assistant', content: 'Done.' },
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, messages)
      
      assert indices.include?(0), "Should include first user (0)"
      assert indices.include?(2), "Should include tool message (2)"
      assert indices.include?(3), "Should include last with content (3)"
    end
    
    test "find_cache_breakpoint_indices caches by position" do
      messages = [
        { role: 'user', content: 'Start' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't1' }] },
        { role: 'tool', tool_call_id: 't1', content: 'result' },
        { role: 'assistant', content: '', tool_calls: [{ id: 't2' }] },
        { role: 'tool', tool_call_id: 't2', content: 'result2' },
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, messages)
      
      # Position-based: first user (0), second-to-last (3), last (4)
      assert indices.include?(0), "Should include first user (0)"
      assert indices.include?(3), "Should include second-to-last (3)"
      assert indices.include?(4), "Should include last (4)"
    end
    
    # =========================================================================
    # Long Conversation Tests
    # =========================================================================
    
    test "long conversation caches strategically" do
      conv_history = []
      
      conv_history << { role: 'user', content: 'Review the project' }
      
      # 10 tool call cycles
      10.times do |i|
        conv_history << {
          role: 'assistant',
          content: '',
          tool_calls: [{ id: "call_#{i}", type: 'function', function: { name: 'read', arguments: '{}' } }]
        }
        conv_history << {
          role: 'tool',
          tool_call_id: "call_#{i}",
          content: "Result #{i}: " + ("x" * 100)
        }
      end
      
      conv_history << { role: 'assistant', content: 'I have reviewed all files.' }
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      cache_positions = find_cache_indices(fixed)
      
      # Should have 3 cache points maximum
      assert cache_positions.size <= 3, "Should have at most 3 cache breakpoints"
      
      # First user should always be cached
      assert cache_positions.include?(0), "First user should be cached"
      
      # Last tool (index 20) should be cached
      assert cache_positions.include?(20), "Last tool message should be cached"
    end
    
    test "total cache_control blocks within Anthropic limit of 4" do
      conv_history = []
      30.times do |i|
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
      
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      total_cache_controls = fixed_hist.sum do |msg|
        next 0 unless msg[:content].is_a?(Array)
        msg[:content].count { |c| c[:cache_control].present? }
      end
      
      assert total_cache_controls <= 3, 
        "Should use at most 3 cache_control blocks, using #{total_cache_controls}"
    end
    
    # =========================================================================
    # Caching Disabled Test
    # =========================================================================
    
    test "no cache_control when caching disabled" do
      LlmToolkit.config.enable_prompt_caching = false
      
      test_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi!' },
        { role: 'tool', tool_call_id: 't1', content: 'result' },
        { role: 'user', content: 'Bye' }
      ]
      
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, test_history)
      
      hist_cache_count = fixed_hist.sum do |msg|
        next 0 unless msg[:content].is_a?(Array)
        msg[:content].count { |c| c[:cache_control].present? }
      end
      
      assert_equal 0, hist_cache_count, "No cache_control when disabled"
    end
    
    # =========================================================================
    # Edge Cases
    # =========================================================================
    
    test "position-based caching includes all positions regardless of content" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: nil },
        { role: 'user', content: 'Continue' }
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, conv_history)
      
      # Position-based: first user (0), second-to-last (1), last (2)
      assert indices.include?(0), "First user should be cached"
      assert indices.include?(1), "Second-to-last should be cached (position-based)"
      assert indices.include?(2), "Last should be cached"
    end
    
    test "position-based caching with whitespace content" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: '   ' },
        { role: 'user', content: 'Continue' }
      ]
      
      indices = @provider.send(:find_cache_breakpoint_indices, conv_history)
      
      # Position-based caching doesn't check content
      assert indices.include?(1), "Second-to-last should be cached (position-based)"
    end
    
    test "tool messages content handling in fix_conversation_history" do
      # Tool messages get processed by fix_conversation_history_for_openrouter
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'tool', tool_call_id: 't1', content: 'First result' },
        { role: 'tool', tool_call_id: 't2', content: 'Second result' },
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Tool messages are processed - verify they exist
      assert_equal 3, fixed.size, "Should have 3 messages"
      assert_equal 'tool', fixed[1][:role], "Second message should be tool"
      assert_equal 'tool', fixed[2][:role], "Third message should be tool"
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
