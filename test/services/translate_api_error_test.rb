require 'test_helper'

module LlmToolkit
  class TranslateApiErrorTest < ActiveSupport::TestCase
    setup do
      # Create a minimal service instance to test the private method
      @llm_provider = mock('LlmProvider')
      @llm_provider.stubs(:provider_type).returns('anthropic')
      
      @llm_model = mock('LlmModel')
      @llm_model.stubs(:llm_provider).returns(@llm_provider)
      
      @conversable = mock('Conversable')
      
      @conversation = mock('Conversation')
      @conversation.stubs(:conversable).returns(@conversable)
      @conversation.stubs(:id).returns(1)
      @conversation.stubs(:update).returns(true)
      @conversation.stubs(:reload).returns(@conversation)
      @conversation.stubs(:status_waiting?).returns(false)
      @conversation.stubs(:waiting?).returns(false)
      @conversation.stubs(:history).returns([])
      @conversation.stubs(:agent_type).returns('coder')
      
      @assistant_message = mock('Message')
      @assistant_message.stubs(:id).returns(1)
      @assistant_message.stubs(:update).returns(true)
      @assistant_message.stubs(:content).returns('')
      
      @service = LlmToolkit::CallStreamingLlmWithToolService.new(
        llm_model: @llm_model,
        conversation: @conversation,
        assistant_message: @assistant_message
      )
    end

    # Helper to call the private method
    def translate_error(message)
      @service.send(:translate_api_error_for_user, message)
    end

    # ===========================================
    # Tests for 400/Invalid Request errors
    # Should now include the actual error message
    # ===========================================

    test "400 error should include the actual error message" do
      error = "Status 400: Invalid parameter 'temperature' must be between 0 and 2"
      result = translate_error(error)
      
      assert_includes result, "erreur de format"
      assert_includes result, "Invalid parameter"
      assert_includes result, "temperature"
    end

    test "invalid request error should include the actual error message" do
      error = "Invalid request: missing required field 'messages'"
      result = translate_error(error)
      
      assert_includes result, "erreur de format"
      assert_includes result, "missing required field"
    end

    test "400 error with long message should be truncated to 300 chars" do
      long_details = "x" * 500
      error = "Status 400: #{long_details}"
      result = translate_error(error)
      
      assert_includes result, "erreur de format"
      # The truncated message should be present but not the full 500 chars
      assert result.length < 500, "Message should be truncated"
      assert_includes result, "..."  # truncate adds ellipsis
    end

    # ===========================================
    # Tests for other error types (unchanged behavior)
    # ===========================================

    test "retry error returns appropriate message" do
      error = "Failed after 3 retries"
      result = translate_error(error)
      
      assert_includes result, "temporairement indisponible"
      assert_includes result, "plusieurs tentatives"
    end

    test "timeout error returns appropriate message" do
      error = "Request timed out after 30 seconds"
      result = translate_error(error)
      
      assert_includes result, "pris trop de temps"
    end

    test "network error returns appropriate message" do
      error = "Network connection failed"
      result = translate_error(error)
      
      assert_includes result, "connexion"
    end

    test "rate limit error returns appropriate message" do
      error = "Rate limit exceeded"
      result = translate_error(error)
      
      assert_includes result, "Trop de requêtes"
    end

    test "429 error returns rate limit message" do
      error = "Status 429: Too many requests"
      result = translate_error(error)
      
      assert_includes result, "Trop de requêtes"
    end

    test "authentication error returns appropriate message" do
      error = "Authentication failed: invalid API key"
      result = translate_error(error)
      
      assert_includes result, "authentification"
    end

    test "401 error returns authentication message" do
      error = "Status 401: Unauthorized"
      result = translate_error(error)
      
      assert_includes result, "authentification"
    end

    test "500 error returns server error message" do
      error = "Status 500: Internal server error"
      result = translate_error(error)
      
      assert_includes result, "difficultés techniques"
    end

    test "502 error returns server error message" do
      error = "Status 502: Bad gateway"
      result = translate_error(error)
      
      assert_includes result, "difficultés techniques"
    end

    test "503 error returns server error message" do
      error = "Status 503: Service unavailable"
      result = translate_error(error)
      
      assert_includes result, "difficultés techniques"
    end

    test "413 error returns context too long message" do
      error = "Status 413: Request entity too large"
      result = translate_error(error)
      
      assert_includes result, "conversation est devenue trop longue"
    end

    test "context too long error returns appropriate message" do
      error = "Maximum context length exceeded"
      result = translate_error(error)
      
      assert_includes result, "conversation est devenue trop longue"
    end

    test "tool not supported error returns appropriate message" do
      error = "Tool use not supported by this model"
      result = translate_error(error)
      
      assert_includes result, "ne prend pas en charge"
    end

    test "content filter error returns appropriate message" do
      error = "Content filtered due to safety concerns"
      result = translate_error(error)
      
      assert_includes result, "filtré"
      assert_includes result, "sécurité"
    end

    test "unknown error includes the original message" do
      error = "Some completely unknown error occurred"
      result = translate_error(error)
      
      assert_includes result, "erreur s'est produite"
      assert_includes result, "unknown error"
    end

    test "unknown error with long message is truncated" do
      long_error = "Error: " + ("detailed info " * 50)
      result = translate_error(long_error)
      
      assert_includes result, "erreur s'est produite"
      # Should be truncated to 150 chars for unknown errors
      assert result.length < long_error.length
    end

    # ===========================================
    # Edge cases
    # ===========================================

    test "empty error message is handled" do
      result = translate_error("")
      
      # Should fall through to the else case
      assert_includes result, "erreur s'est produite"
    end

    test "nil-like error message is handled" do
      result = translate_error("nil")
      
      assert_includes result, "erreur s'est produite"
    end

    test "error with special characters is handled" do
      error = "Status 400: Invalid JSON: unexpected token '<' at position 0"
      result = translate_error(error)
      
      assert_includes result, "erreur de format"
      assert_includes result, "Invalid JSON"
    end

    test "error with unicode is handled" do
      error = "Status 400: Le paramètre 'température' est invalide"
      result = translate_error(error)
      
      assert_includes result, "erreur de format"
      assert_includes result, "température"
    end
  end
end
