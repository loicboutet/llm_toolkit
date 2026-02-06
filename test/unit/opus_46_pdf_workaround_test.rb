# frozen_string_literal: true

require "test_helper"

module LlmToolkit
  class Opus46PdfWorkaroundTest < ActiveSupport::TestCase
    setup do
      @provider = LlmToolkit::LlmProvider.create!(
        name: "Test OpenRouter",
        provider_type: "openrouter",
        api_key: "test_key"
      )
    end

    test "model_has_pdf_tool_result_bug? returns true for opus 4.6" do
      assert @provider.send(:model_has_pdf_tool_result_bug?, "anthropic/claude-opus-4.6")
    end

    test "model_has_pdf_tool_result_bug? returns false for opus 4.5" do
      refute @provider.send(:model_has_pdf_tool_result_bug?, "anthropic/claude-opus-4.5")
    end

    test "model_has_pdf_tool_result_bug? returns false for nil" do
      refute @provider.send(:model_has_pdf_tool_result_bug?, nil)
    end

    test "strip_pdf_files_from_history removes file parts" do
      messages = [
        {
          role: "user",
          content: [
            { type: "text", text: "Hello" },
            { type: "file", file: { filename: "test.pdf", file_data: "base64data" } }
          ]
        },
        {
          role: "assistant",
          content: "Response"
        }
      ]

      result = @provider.send(:strip_pdf_files_from_history, messages)

      # First message should have file removed
      assert_equal 2, result[0][:content].length  # text + note
      assert_equal "text", result[0][:content][0][:type]
      assert_includes result[0][:content][1][:text], "file attachment"

      # Second message unchanged
      assert_equal "Response", result[1][:content]
    end

    test "strip_pdf_files_from_history keeps messages without files unchanged" do
      messages = [
        { role: "user", content: [{ type: "text", text: "Hello" }] },
        { role: "assistant", content: "Response" }
      ]

      result = @provider.send(:strip_pdf_files_from_history, messages)

      assert_equal messages, result
    end

    test "fix_conversation_history_for_openrouter strips PDFs for opus 4.6 when tool messages present" do
      messages = [
        {
          role: "user",
          content: [
            { type: "text", text: "Hello" },
            { type: "file", file: { filename: "test.pdf", file_data: "base64data" } }
          ]
        },
        {
          role: "assistant",
          content: "",
          tool_calls: [{ id: "toolu_123", type: "function", function: { name: "test", arguments: "{}" } }]
        },
        {
          role: "tool",
          tool_call_id: "toolu_123",
          name: "test",
          content: "Tool result"
        }
      ]

      result = @provider.send(:fix_conversation_history_for_openrouter, messages, model_name: "anthropic/claude-opus-4.6")

      # PDF should be stripped
      refute result[0][:content].any? { |part| part[:type] == "file" }
    end

    test "fix_conversation_history_for_openrouter keeps PDFs for opus 4.5" do
      messages = [
        {
          role: "user",
          content: [
            { type: "text", text: "Hello" },
            { type: "file", file: { filename: "test.pdf", file_data: "base64data" } }
          ]
        },
        {
          role: "assistant",
          content: "",
          tool_calls: [{ id: "toolu_123", type: "function", function: { name: "test", arguments: "{}" } }]
        },
        {
          role: "tool",
          tool_call_id: "toolu_123",
          name: "test",
          content: "Tool result"
        }
      ]

      result = @provider.send(:fix_conversation_history_for_openrouter, messages, model_name: "anthropic/claude-opus-4.5")

      # PDF should NOT be stripped for opus 4.5
      assert result[0][:content].any? { |part| part[:type] == "file" }
    end

    test "fix_conversation_history_for_openrouter keeps PDFs for opus 4.6 when NO tool messages" do
      messages = [
        {
          role: "user",
          content: [
            { type: "text", text: "Hello" },
            { type: "file", file: { filename: "test.pdf", file_data: "base64data" } }
          ]
        },
        {
          role: "assistant",
          content: "Response without tools"
        }
      ]

      result = @provider.send(:fix_conversation_history_for_openrouter, messages, model_name: "anthropic/claude-opus-4.6")

      # PDF should NOT be stripped when no tools
      assert result[0][:content].any? { |part| part[:type] == "file" }
    end
  end
end
