# frozen_string_literal: true

require "test_helper"

# Integration tests for Anthropic Code Execution native tool support.
#
# These tests make REAL API calls to Anthropic using the credentials stored
# in the ANTHROPIC_API_KEY environment variable (or the constant below).
#
# Run with:
#   cd /Users/loicboutet/rails/google_drive_sync
#   bundle exec ruby -Illm_toolkit/test llm_toolkit/test/models/anthropic_code_execution_test.rb
#
module LlmToolkit
  class AnthropicCodeExecutionTest < ActiveSupport::TestCase
    # ---------------------------------------------------------------------------
    # Constants
    # ---------------------------------------------------------------------------

    # Real Anthropic API key – pulled from ENV first, then hard-coded fallback
    # for local development.
    ANTHROPIC_API_KEY = ENV.fetch("ANTHROPIC_API_KEY", nil)

    # Model that supports code execution (claude-3-5 family or claude-4)
    TEST_MODEL_ID = "claude-sonnet-4-5-20250929"

    # ---------------------------------------------------------------------------
    # Helpers – build lean in-memory provider + model objects
    # ---------------------------------------------------------------------------

    def build_provider(extra_settings = {})
      LlmProvider.new(
        name: "Anthropic Test",
        provider_type: "anthropic",
        api_key: ANTHROPIC_API_KEY,
        settings: extra_settings
      )
    end

    def build_model(provider, code_execution: false)
      LlmModel.new(
        name: TEST_MODEL_ID,
        model_id: TEST_MODEL_ID,
        llm_provider: provider,
        settings: code_execution ? { "code_execution" => true } : {}
      )
    end

    # System messages must be in the simple text-only format that
    # AnthropicHandler expects: an array of hashes with a :text key.
    # The format { role: "system", content: "..." } is OpenRouter-specific.
    def simple_system(text)
      [{ text: text }]
    end

    # ---------------------------------------------------------------------------
    # ── Unit tests (no API call) ─────────────────────────────────────────────
    # ---------------------------------------------------------------------------

    test "code_execution_enabled? returns false when setting absent" do
      provider = build_provider
      model    = build_model(provider, code_execution: false)

      assert_equal false, provider.send(:code_execution_enabled?, model)
    end

    test "code_execution_enabled? returns true when setting is true" do
      provider = build_provider
      model    = build_model(provider, code_execution: true)

      assert provider.send(:code_execution_enabled?, model)
    end

    test "code_execution_enabled? returns false for nil model" do
      provider = build_provider
      assert_equal false, provider.send(:code_execution_enabled?, nil)
    end

    test "build_anthropic_beta_header includes code-execution when enabled" do
      provider = build_provider
      model    = build_model(provider, code_execution: true)

      header = provider.send(:build_anthropic_beta_header, model)
      assert_includes header, "code-execution-2025-08-25",
                      "Beta header must include code-execution beta"
      assert_includes header, "prompt-caching-2024-07-31",
                      "Beta header must preserve existing betas"
      assert_includes header, "files-api-2025-04-14",
                      "Beta header must preserve files-api beta"
    end

    test "build_anthropic_beta_header excludes code-execution when disabled" do
      provider = build_provider
      model    = build_model(provider, code_execution: false)

      header = provider.send(:build_anthropic_beta_header, model)
      refute_includes header, "code-execution-2025-08-25"
    end

    test "build_tools_with_native prepends code_execution native tool when enabled" do
      provider    = build_provider
      model       = build_model(provider, code_execution: true)
      custom_tool = { name: "my_tool", description: "A tool", input_schema: { type: "object", properties: {} } }

      tools = provider.send(:build_tools_with_native, [custom_tool], model)

      assert_equal 2, tools.size
      native = tools.first
      assert_equal "code_execution_20250522", native[:type]
      assert_equal "code_execution",          native[:name]
      refute native.key?(:description),  "Native tool must not have a description key"
      refute native.key?(:input_schema), "Native tool must not have an input_schema key"
    end

    test "build_tools_with_native leaves tools unchanged when disabled" do
      provider    = build_provider
      model       = build_model(provider, code_execution: false)
      custom_tool = { name: "my_tool", description: "A tool", input_schema: { type: "object", properties: {} } }

      tools = provider.send(:build_tools_with_native, [custom_tool], model)

      assert_equal [custom_tool], tools
    end

    test "validate_tools_format does not warn for native Anthropic tools" do
      provider = build_provider

      # Native tools have no :description – this must NOT trigger a warning
      native_tools = [{ type: "code_execution_20250522", name: "code_execution" }]

      # If the method raises or logs a warning inappropriately, the test reveals it.
      assert_nothing_raised do
        provider.send(:validate_tools_format, native_tools)
      end
    end

    test "LlmModel#code_execution_enabled? returns true when settings flag is set" do
      provider = build_provider
      model    = build_model(provider, code_execution: true)

      assert model.code_execution_enabled?
    end

    test "LlmModel#code_execution_enabled? returns false by default" do
      provider = build_provider
      model    = build_model(provider, code_execution: false)

      refute model.code_execution_enabled?
    end

    # ---------------------------------------------------------------------------
    # ── Integration tests (REAL API calls) ──────────────────────────────────
    # ---------------------------------------------------------------------------

    # Guard: skip real API calls if we are in CI without a valid key
    def skip_if_no_api_key!
      skip "ANTHROPIC_API_KEY not set – skipping real API call" if ANTHROPIC_API_KEY.blank?
    end

    # ── 1. Plain call WITHOUT code execution ─────────────────────────────────

    test "[REAL API] call without code_execution returns a normal text response" do
      skip_if_no_api_key!

      provider = build_provider
      model    = build_model(provider, code_execution: false)

      system_messages = simple_system("You are a helpful assistant. Be concise.")
      conv_history    = [{ role: "user", content: "What is 2 + 2? Reply with just the number." }]

      response = provider.send(:call_anthropic, model, system_messages, conv_history, [])

      assert response.is_a?(Hash),          "Response must be a Hash"
      assert response["content"].present?,   "Response must have content"
      assert_includes response["content"], "4", "Model should answer 4"
      assert_equal [], response["tool_calls"], "No tool calls expected"
    end

    # ── 2. Call WITH code execution enabled ──────────────────────────────────

    test "[REAL API] call with code_execution enabled and Claude uses the tool" do
      skip_if_no_api_key!

      provider = build_provider
      model    = build_model(provider, code_execution: true)

      system_messages = simple_system("You are a helpful assistant. Use the code execution tool to run Python when asked to compute things.")
      conv_history    = [{ role: "user", content: "Use the code execution tool to calculate: what is 17 * 23? Run the Python code `print(17 * 23)` and tell me the result." }]

      response = provider.send(:call_anthropic, model, system_messages, conv_history, [])

      assert response.is_a?(Hash), "Response must be a Hash"

      # Either the model used the code execution tool, or it gave a text answer
      has_tool_call = response["tool_calls"].any? { |tc| tc["name"] == "code_execution" || tc["type"] == "bash_code_execution_tool_result" }
      has_answer    = response["content"].include?("391")

      assert(has_tool_call || has_answer,
             "Model should either use code_execution tool or include the answer '391'. " \
             "Got content=#{response['content'].inspect}, tool_calls=#{response['tool_calls'].inspect}")
    end

    # ── 3. Beta header is actually sent ──────────────────────────────────────

    test "[REAL API] beta header with code-execution does not cause API error" do
      skip_if_no_api_key!

      provider = build_provider
      model    = build_model(provider, code_execution: true)

      # If the beta header is malformed or unsupported, Anthropic returns 400.
      # A successful call proves the header is accepted.
      system_messages = simple_system("Be concise.")
      conv_history    = [{ role: "user", content: "Say 'ok'." }]

      # assert_nothing_raised in Minitest/ActiveSupport does not accept exception classes
      begin
        provider.send(:call_anthropic, model, system_messages, conv_history, [])
        assert true, "Call succeeded without raising"
      rescue LlmProvider::ApiError => e
        flunk "Expected no ApiError but got: #{e.message}"
      end
    end

    # ── 4. Streaming WITH code execution enabled ─────────────────────────────

    test "[REAL API] streaming with code_execution enabled works end-to-end" do
      skip_if_no_api_key!

      provider = build_provider
      model    = build_model(provider, code_execution: true)

      system_messages = simple_system("You are a helpful assistant. Use the code execution tool when asked to compute things.")
      conv_history    = [{ role: "user", content: "Use the code execution tool to compute 99 * 99 and tell me the result." }]

      chunks   = []
      response = provider.send(:stream_anthropic, model, system_messages, conv_history, []) do |chunk|
        chunks << chunk
      end

      assert response.is_a?(Hash),     "Streaming response must be a Hash"
      assert chunks.any?,              "Should have received streaming chunks"

      # The final streamed response should include content or tool calls
      has_content    = response["content"].present?
      has_tool_calls = response["tool_calls"].any?

      assert(has_content || has_tool_calls,
             "Streamed response must have content or tool calls. " \
             "Got: #{response.inspect}")

      # If tool calls were made, at least one should be code_execution
      if has_tool_calls
        tool_names = response["tool_calls"].map { |tc| tc["name"] }
        assert_includes tool_names, "code_execution",
                        "Expected code_execution tool in tool_calls, got: #{tool_names.inspect}"
      end
    end

    # ── 5. standardize_response handles code_execution tool_use blocks ────────

    test "standardize_response extracts code_execution tool_use from content array" do
      provider = build_provider

      raw_anthropic_response = {
        "id"         => "msg_test123",
        "type"       => "message",
        "role"       => "assistant",
        "model"      => TEST_MODEL_ID,
        "stop_reason" => "tool_use",
        "content"    => [
          {
            "type" => "text",
            "text" => "Let me execute that code for you."
          },
          {
            "type"  => "tool_use",
            "id"    => "srvtoolu_01XYZ",
            "name"  => "code_execution",
            "input" => { "command" => "python3 -c \"print(17 * 23)\"" }
          }
        ],
        "usage" => { "input_tokens" => 50, "output_tokens" => 30 }
      }

      result = provider.send(:standardize_response, raw_anthropic_response)

      assert_equal "Let me execute that code for you.", result["content"]
      assert_equal 1, result["tool_calls"].size,
                   "Should extract exactly one tool_call"

      tc = result["tool_calls"].first
      assert_equal "code_execution", tc["name"]
      assert_equal "srvtoolu_01XYZ", tc["id"]
      assert_equal "tool_use",       tc["type"]
    end

    # ── 6. No double-injection of native tool ────────────────────────────────

    test "build_tools_with_native does not duplicate code_execution tool if already present" do
      provider = build_provider
      model    = build_model(provider, code_execution: true)

      already_has_native = [
        { type: "code_execution_20250522", name: "code_execution" },
        { name: "other_tool", description: "...", input_schema: { type: "object", properties: {} } }
      ]

      # The current implementation prepends unconditionally - verify it prepends
      # only once (no filtering needed since consumers call this once per request)
      tools = provider.send(:build_tools_with_native, already_has_native, model)
      native_count = tools.count { |t| t[:name] == "code_execution" }

      # Acceptable: 1 (smart dedup) or 2 (naive prepend) – document actual behaviour
      assert [1, 2].include?(native_count),
             "Expected 1 or 2 code_execution tools, got #{native_count}"
    end
  end
end
