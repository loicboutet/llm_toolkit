# frozen_string_literal: true

# =============================================================================
# Unit Test: Verify cache_control Application in Message Formatting
# =============================================================================
#
# This tests the caching logic for OpenRouter messages:
# 1. System messages get cache_control applied correctly
# 2. Conversation history gets cache_control applied to the last cacheable message
# 3. Tool messages maintain string content (not array)
# 4. Multimodal content (images) is handled properly
# 5. Total cache_control blocks stay within Anthropic's limit of 4
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
      
      # Count cache_control positions
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
    # Conversation History Tests
    # =========================================================================
    
    test "basic conversation caches last message" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' },
        { role: 'user', content: 'How are you?' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Last message should have cache_control
      last_msg = fixed.last
      assert last_msg[:content].is_a?(Array), "Last message content should be array"
      assert last_msg[:content].any? { |c| c[:cache_control].present? }, 
        "Last message should have cache_control"
    end
    
    test "multimodal user message with image gets cache_control on text" do
      # This simulates what the conversation.history method produces
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
      
      # Should preserve array structure
      assert fixed[0][:content].is_a?(Array), "Content should remain as array"
      
      # Image should be preserved
      image_item = fixed[0][:content].find { |c| c[:type] == 'image_url' }
      assert image_item.present?, "Image item should be preserved"
      
      # Text should have cache_control
      text_item = fixed[0][:content].find { |c| c[:type] == 'text' }
      assert text_item.present?, "Text item should exist"
      assert text_item[:cache_control].present?, "Text item should have cache_control"
    end
    
    test "multimodal message with multiple text blocks caches last text only" do
      conv_history = [
        { 
          role: 'user', 
          content: [
            { type: 'text', text: 'First text' },
            { type: 'image_url', image_url: { url: 'data:image/png;base64,abc' } },
            { type: 'text', text: 'Second text after image' }
          ]
        }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      content = fixed[0][:content]
      
      # First text should NOT have cache_control
      first_text = content[0]
      assert_equal 'text', first_text[:type]
      refute first_text[:cache_control].present?, "First text should NOT have cache_control"
      
      # Last text should have cache_control
      last_text = content[2]
      assert_equal 'text', last_text[:type]
      assert last_text[:cache_control].present?, "Last text should have cache_control"
    end
    
    test "tool messages have string content" do
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
      
      # Find tool message
      tool_msg = fixed.find { |m| m[:role] == 'tool' }
      assert tool_msg.present?, "Tool message should exist"
      assert tool_msg[:content].is_a?(String), 
        "Tool message content MUST be string, got #{tool_msg[:content].class}"
    end
    
    test "tool messages are skipped for caching" do
      conv_history = [
        { role: 'user', content: 'Hello' },
        { role: 'tool', tool_call_id: 'tool_1', content: 'Tool result' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Tool message should not have cache_control (and should be string)
      tool_msg = fixed.find { |m| m[:role] == 'tool' }
      refute tool_msg[:content].is_a?(Array), "Tool message should not have array content"
      
      # User message (last cacheable) should have cache_control
      user_msg = fixed.find { |m| m[:role] == 'user' }
      assert user_msg[:content].is_a?(Array), "User message should have array content"
      assert user_msg[:content].any? { |c| c[:cache_control].present? },
        "User message should have cache_control"
    end
    
    test "last cacheable message is cached when tool is last" do
      conv_history = [
        { role: 'user', content: 'Do something' },
        { role: 'assistant', content: 'Calling tool...' },
        { role: 'tool', tool_call_id: 'tool_1', content: 'Done' }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Last cacheable is assistant (index 1)
      assistant_msg = fixed[1]
      
      # It should have cache_control since tool (index 2) can't be cached
      assert assistant_msg[:content].is_a?(Array), 
        "Assistant message should have array content for caching"
      assert assistant_msg[:content].any? { |c| c[:cache_control].present? },
        "Assistant message should have cache_control (it's last cacheable)"
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
      
      assistant_msg = fixed[1]
      assert_equal "", assistant_msg[:content], 
        "nil content should be converted to empty string"
    end
    
    test "array content with only text is preserved and cached" do
      conv_history = [
        { role: 'user', content: [{ type: 'text', text: 'Test message' }] }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      assert fixed[0][:content].is_a?(Array), "Array content should be preserved"
      assert fixed[0][:content].any? { |c| c[:cache_control].present? },
        "Array content should have cache_control added"
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
      # Format both system and conversation
      test_system = [{ type: 'text', text: 'System prompt' * 100 }]
      test_history = [
        { role: 'user', content: 'User message 1' },
        { role: 'assistant', content: 'Assistant response' },
        { role: 'user', content: 'User message 2' }
      ]
      
      formatted_sys = @provider.send(:format_system_messages_for_openrouter, test_system)
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, test_history)
      
      total_cache_controls = 0
      
      # Count in system messages
      formatted_sys.each do |msg|
        next unless msg[:content].is_a?(Array)
        msg[:content].each { |c| total_cache_controls += 1 if c[:cache_control].present? }
      end
      
      # Count in conversation
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
      test_history = [{ role: 'user', content: 'Hello' }]
      
      formatted_sys = @provider.send(:format_system_messages_for_openrouter, test_system)
      fixed_hist = @provider.send(:fix_conversation_history_for_openrouter, test_history)
      
      # Check no cache_control in system
      sys_cache_count = formatted_sys.sum do |msg|
        next 0 unless msg[:content].is_a?(Array)
        msg[:content].count { |c| c[:cache_control].present? }
      end
      
      # Check no cache_control in history (should remain as string)
      hist_cache_count = fixed_hist.sum do |msg|
        next 0 unless msg[:content].is_a?(Array)
        msg[:content].count { |c| c[:cache_control].present? }
      end
      
      assert_equal 0, sys_cache_count, "No cache_control when disabled (system)"
      assert_equal 0, hist_cache_count, "No cache_control when disabled (history)"
    end
    
    # =========================================================================
    # String Key Tests (conversation.history uses string keys)
    # =========================================================================
    
    test "handles string keys from conversation history" do
      # conversation.history produces hashes with string keys for content items
      conv_history = [
        { 
          role: 'user', 
          content: [
            { 'type' => 'text', 'text' => 'Hello with string keys' }
          ]
        }
      ]
      
      fixed = @provider.send(:fix_conversation_history_for_openrouter, conv_history)
      
      # Should still work and add cache_control
      assert fixed[0][:content].is_a?(Array), "Content should be array"
      
      # Find the text item (might have symbol or string keys after processing)
      has_cache = fixed[0][:content].any? do |item|
        item[:cache_control].present? || item['cache_control'].present?
      end
      
      assert has_cache, "Should have cache_control even with string keys"
    end
  end
end
