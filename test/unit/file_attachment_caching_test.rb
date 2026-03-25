# frozen_string_literal: true

require 'test_helper'

class FileAttachmentCachingTest < ActiveSupport::TestCase
  def setup
    @provider = LlmToolkit::LlmProvider.new(
      name: 'Test Provider',
      api_key: 'test-key',
      provider_type: 'openrouter'
    )
    LlmToolkit.config.enable_prompt_caching = true
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test 1: apply_cache_control_to_last_block does NOT add cache_control to file blocks
  # ─────────────────────────────────────────────────────────────────────────────
  test "apply_cache_control_to_last_block puts cache_control on text block, not file block" do
    content = [
      { type: 'text', text: 'Please analyze this PDF' },
      { type: 'file', file: { filename: 'doc.pdf', file_data: 'data:application/pdf;base64,abc123' } }
    ]

    result = @provider.send(:apply_cache_control_to_last_block, content)

    text_block = result.find { |b| b[:type] == 'text' }
    file_block = result.find { |b| b[:type] == 'file' }

    assert_not_nil text_block[:cache_control],
      "Expected cache_control on the text block"
    assert_equal({ type: 'ephemeral' }, text_block[:cache_control])

    assert_nil file_block[:cache_control],
      "cache_control must NOT be placed on a file block — Anthropic/OpenRouter does not support it"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test 2: apply_cache_control_to_last_block — image_url scenario
  # ─────────────────────────────────────────────────────────────────────────────
  test "apply_cache_control_to_last_block puts cache_control on text block, not image_url block" do
    content = [
      { type: 'text', text: 'What is in this image?' },
      { type: 'image_url', image_url: { url: 'data:image/png;base64,abc123' } }
    ]

    result = @provider.send(:apply_cache_control_to_last_block, content)

    text_block  = result.find { |b| b[:type] == 'text' }
    image_block = result.find { |b| b[:type] == 'image_url' }

    assert_not_nil text_block[:cache_control],
      "Expected cache_control on the text block"
    assert_equal({ type: 'ephemeral' }, text_block[:cache_control])

    assert_nil image_block[:cache_control],
      "cache_control must NOT be placed on an image_url block"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test 3: No text block at all (image-only message) — must return unchanged
  # ─────────────────────────────────────────────────────────────────────────────
  test "apply_cache_control_to_last_block does not add cache_control when no text block exists" do
    content = [
      { type: 'image_url', image_url: { url: 'data:image/png;base64,abc123' } }
    ]

    result = @provider.send(:apply_cache_control_to_last_block, content)

    image_block = result.find { |b| b[:type] == 'image_url' }

    assert_nil image_block[:cache_control],
      "cache_control must NOT be added when there is no text block (image-only message)"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test 4: File-only message — must return unchanged
  # ─────────────────────────────────────────────────────────────────────────────
  test "apply_cache_control_to_last_block does not add cache_control when message has only file block" do
    content = [
      { type: 'file', file: { filename: 'doc.pdf', file_data: 'data:application/pdf;base64,abc123' } }
    ]

    result = @provider.send(:apply_cache_control_to_last_block, content)

    file_block = result.find { |b| b[:type] == 'file' }

    assert_nil file_block[:cache_control],
      "cache_control must NOT be added to a file block when no text block exists"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test: Empty text block — must NOT get cache_control (real bug from conv 10416)
  # User sends files with no text → text block is "" → Anthropic rejects cache_control
  # with "cache_control cannot be set for empty text blocks"
  # ─────────────────────────────────────────────────────────────────────────────
  test "apply_cache_control_to_last_block does not add cache_control on empty text block" do
    content = [
      { type: 'text', text: '' },
      { type: 'file', file: { filename: 'doc.pdf', file_data: 'data:application/pdf;base64,abc' } }
    ]

    result = @provider.send(:apply_cache_control_to_last_block, content)

    result.each do |block|
      assert_nil block[:cache_control],
        "cache_control must NOT be set on any block when text is empty — got it on '#{block[:type]}' block"
    end
  end

  test "apply_cache_control_to_last_block does not add cache_control when all text blocks are empty" do
    content = [
      { type: 'text', text: '' },
      { type: 'text', text: '   ' },
    ]

    result = @provider.send(:apply_cache_control_to_last_block, content)

    result.each do |block|
      assert_nil block[:cache_control],
        "cache_control must NOT be set when all text blocks are blank"
    end
  end

  test "full pipeline: no cache_control when first user message has only files and empty text" do
    messages = [
      {
        role: 'user',
        content: [
          { type: 'text', text: '' },
          { type: 'file', file: { filename: 'a.pdf', file_data: 'data:application/pdf;base64,abc' } },
          { type: 'file', file: { filename: 'b.pdf', file_data: 'data:application/pdf;base64,def' } },
        ]
      },
      { role: 'assistant', content: "J'ai bien reçu les documents." },
      { role: 'user', content: [{ type: 'text', text: 'Fais une comparaison.' }] }
    ]

    result = @provider.send(:fix_conversation_history_for_openrouter, messages)

    result.each do |message|
      next unless message[:content].is_a?(Array)
      message[:content].each do |block|
        if block[:type] == 'text' && block[:text].blank?
          assert_nil block[:cache_control],
            "cache_control must NOT be set on empty text blocks — this causes Anthropic 400 errors"
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test 5: Full pipeline — fix_conversation_history_for_openrouter does not
  #         put cache_control on file blocks in a multi-turn conversation
  # ─────────────────────────────────────────────────────────────────────────────
  test "fix_conversation_history_for_openrouter does not put cache_control on file blocks in multi-turn conversation" do
    messages = [
      # Turn 1 — user message with text + PDF
      {
        role: 'user',
        content: [
          { type: 'text', text: 'Please analyze this PDF' },
          { type: 'file', file: { filename: 'doc.pdf', file_data: 'data:application/pdf;base64,abc123' } }
        ]
      },
      # Assistant response
      {
        role: 'assistant',
        content: 'I have analyzed the PDF. It contains important information.'
      },
      # Turn 2 — follow-up question
      {
        role: 'user',
        content: [
          { type: 'text', text: 'Can you summarize the key points?' }
        ]
      }
    ]

    result = @provider.send(:fix_conversation_history_for_openrouter, messages)

    result.each do |message|
      next unless message[:content].is_a?(Array)

      message[:content].each do |block|
        block_type = block[:type] || block['type']
        if block_type == 'file'
          assert_nil block[:cache_control],
            "cache_control must NEVER appear on a file block — found one in message: #{message.inspect}"
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Test 6: Full pipeline — cache_control IS correctly placed on text blocks
  # ─────────────────────────────────────────────────────────────────────────────
  test "fix_conversation_history_for_openrouter correctly places cache_control on text blocks" do
    messages = [
      {
        role: 'user',
        content: [
          { type: 'text', text: 'Please analyze this PDF' },
          { type: 'file', file: { filename: 'doc.pdf', file_data: 'data:application/pdf;base64,abc123' } }
        ]
      },
      {
        role: 'assistant',
        content: 'Analysis complete.'
      },
      {
        role: 'user',
        content: [
          { type: 'text', text: 'Summarize the key points.' }
        ]
      }
    ]

    result = @provider.send(:fix_conversation_history_for_openrouter, messages)

    # Collect all blocks that have cache_control
    cached_blocks = []
    result.each do |message|
      next unless message[:content].is_a?(Array)
      message[:content].each do |block|
        cached_blocks << block if block[:cache_control]
      end
    end

    # All cached blocks must be text type
    cached_blocks.each do |block|
      assert_equal 'text', block[:type],
        "cache_control should only appear on 'text' blocks, found it on '#{block[:type]}' block"
    end
  end
end
