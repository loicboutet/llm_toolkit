require 'test_helper'

module LlmToolkit
  class StreamingRetryTest < ActiveSupport::TestCase
    # Test that the OpenRouter handler retries on transient errors
    # This is a unit test for the retry mechanism
    
    class MockToolUses
      def exists?(*args); false; end
      def find_by(*args); nil; end
      def create!(*args); OpenStruct.new(id: 1); end
    end

    class MockMessage
      attr_accessor :id, :content, :is_error, :finish_reason, :llm_model_id
      
      def initialize
        @id = 1
        @content = ''
        @is_error = false
        @llm_model_id = 1
        @updates = []
      end
      
      def update(attrs = {})
        @updates << attrs
        attrs.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
        true
      end
      
      def tool_uses
        MockToolUses.new
      end
      
      def updates
        @updates
      end
    end

    class MockMessages
      def initialize(message)
        @message = message
      end
      
      def create!(*args); @message; end
      def where(*args); self; end
      def order(*args); self; end
      def first; @message; end
    end

    class MockConversable
      def respond_to?(method)
        method == :generate_system_messages
      end
      
      def generate_system_messages(*args)
        []
      end
    end

    class MockConversation
      attr_accessor :status, :id, :message
      
      def initialize(message)
        @status = :resting
        @id = 1
        @message = message
        @canceled = false
      end
      
      def update(attrs = {})
        @status = attrs[:status] if attrs[:status]
        true
      end
      
      def reload; self; end
      def status_waiting?; @status == :waiting; end
      def waiting?; @status == :waiting; end
      def canceled?; @canceled; end
      def cancel!; @canceled = true; end
      def conversable; MockConversable.new; end
      def messages; MockMessages.new(@message); end
      def history(*args); []; end
      def respond_to?(method, *args)
        [:context_window_info, :sub_agent?].include?(method) ? false : super
      end
    end

    test "openrouter handler retries 3 times on network timeout before failing" do
      # Create a real provider to test the actual behavior
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      # Override Faraday to track calls and simulate timeout
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        # Override the post method to simulate timeout
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          raise Faraday::TimeoutError.new("Connection timed out")
        end
        
        conn
      end
      
      begin
        error = assert_raises(LlmToolkit::LlmProvider::ApiError) do
          provider.send(:stream_openrouter, llm_model, [], [], nil) { |chunk| }
        end
        
        # Error message should mention the retries
        assert_match(/after 3 retries/, error.message)
        
        # With retry mechanism, API should be called 3 times
        assert_equal 3, call_count, "API should be called 3 times with retry mechanism"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end

    test "openrouter handler retries 3 times on 500 error before failing" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          # Return a 500 error response
          OpenStruct.new(
            status: 500,
            body: nil,
            headers: {}
          )
        end
        
        conn
      end
      
      begin
        error = assert_raises(LlmToolkit::LlmProvider::ApiError) do
          provider.send(:stream_openrouter, llm_model, [], [], nil) { |chunk| }
        end
        
        assert_match(/API streaming error/, error.message)
        
        # With retry mechanism, should call 3 times
        assert_equal 3, call_count, "API should be called 3 times with retry mechanism on 500 error"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end

    test "openrouter handler retries 3 times on 503 service unavailable before failing" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          OpenStruct.new(
            status: 503,
            body: nil,
            headers: {}
          )
        end
        
        conn
      end
      
      begin
        error = assert_raises(LlmToolkit::LlmProvider::ApiError) do
          provider.send(:stream_openrouter, llm_model, [], [], nil) { |chunk| }
        end
        
        assert_match(/API streaming error/, error.message)
        
        # With retry mechanism, should call 3 times
        assert_equal 3, call_count, "API should be called 3 times with retry mechanism on 503 error"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end

    test "streaming service updates message with error when API fails" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      message = MockMessage.new
      conversation = MockConversation.new(message)
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          raise Faraday::TimeoutError.new("Connection timed out")
        end
        
        conn
      end
      
      begin
        service = LlmToolkit::CallStreamingLlmWithToolService.new(
          llm_model: llm_model,
          conversation: conversation,
          assistant_message: message,
          tool_classes: [],
          user_id: 1
        )
        
        result = service.call
        
        # Service should return false on error
        assert_equal false, result, "Service should return false when API call fails"
        
        # Message should contain error content
        assert message.content.present?, "Message should have error content"
        
        # Message should be marked as error
        assert message.is_error, "Message should be marked as error"
        
        # Message should have finish_reason set
        assert_equal 'error', message.finish_reason, "Message should have finish_reason = 'error'"
        
        # Content should be user-friendly French message
        assert_match(/⚠️/, message.content, "Error message should have warning emoji")
        assert_match(/temporairement|réessayer|indisponible/i, message.content, "Error message should be in French")
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end
    
    test "streaming service shows friendly message for different error types" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      # Test rate limit error message
      message = MockMessage.new
      conversation = MockConversation.new(message)
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          # Return 429 rate limit error
          OpenStruct.new(
            status: 429,
            body: nil,
            headers: {}
          )
        end
        
        conn
      end
      
      begin
        service = LlmToolkit::CallStreamingLlmWithToolService.new(
          llm_model: llm_model,
          conversation: conversation,
          assistant_message: message,
          tool_classes: [],
          user_id: 1
        )
        
        result = service.call
        
        # Should show rate limit message
        assert_match(/Trop de requêtes|patienter/i, message.content, "Should show rate limit message")
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end

    # =========================================================================
    # Tests for successful retry behavior
    # =========================================================================

    test "should succeed after transient failures when retry eventually works" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          
          # Fail first two times, succeed on third
          if call_count < 3
            raise Faraday::TimeoutError.new("Connection timed out")
          else
            # Simulate a successful streaming response
            if post_block
              req = OpenStruct.new(
                headers: {},
                body: nil,
                options: OpenStruct.new(on_data: nil)
              )
              post_block.call(req)
              
              # If on_data callback was set, call it with success data
              if req.options.on_data
                req.options.on_data.call("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n", 0, nil)
                req.options.on_data.call("data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1}}\n\n", 0, nil)
                req.options.on_data.call("data: [DONE]\n\n", 0, nil)
              end
            end
            
            OpenStruct.new(
              status: 200,
              body: nil,
              headers: {}
            )
          end
        end
        
        conn
      end
      
      begin
        received_content = []
        result = provider.send(:stream_openrouter, llm_model, [], [], nil) do |chunk|
          received_content << chunk if chunk[:chunk_type] == 'content'
        end
        
        # Should succeed after 2 failures + 1 success
        assert_equal 3, call_count, "Expected 3 attempts (2 failures + 1 success)"
        assert_equal "Hello", result['content'], "Should have received streamed content"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end

    test "should NOT retry on 400 client errors" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          OpenStruct.new(
            status: 400,
            body: nil,
            headers: {}
          )
        end
        
        conn
      end
      
      begin
        assert_raises(LlmToolkit::LlmProvider::ApiError) do
          provider.send(:stream_openrouter, llm_model, [], [], nil) { |chunk| }
        end
        
        # 400 errors are NOT retryable - should only call once
        assert_equal 1, call_count, "400 client errors should NOT be retried"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end
    
    test "should NOT retry on 401 authentication errors" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          OpenStruct.new(
            status: 401,
            body: nil,
            headers: {}
          )
        end
        
        conn
      end
      
      begin
        assert_raises(LlmToolkit::LlmProvider::ApiError) do
          provider.send(:stream_openrouter, llm_model, [], [], nil) { |chunk| }
        end
        
        # 401 errors are NOT retryable
        assert_equal 1, call_count, "401 authentication errors should NOT be retried"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end

    test "should NOT retry on 429 rate limit errors" do
      provider = LlmToolkit::LlmProvider.new(
        name: 'test_provider',
        provider_type: 'openrouter',
        api_key: 'test_key'
      )
      
      llm_model = OpenStruct.new(
        model_id: 'anthropic/claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        llm_provider: provider
      )
      
      call_count = 0
      
      original_new = Faraday.method(:new)
      Faraday.define_singleton_method(:new) do |*args, &block|
        conn = original_new.call(*args, &block)
        
        conn.define_singleton_method(:post) do |*post_args, &post_block|
          call_count += 1
          OpenStruct.new(
            status: 429,
            body: nil,
            headers: {}
          )
        end
        
        conn
      end
      
      begin
        assert_raises(LlmToolkit::LlmProvider::ApiError) do
          provider.send(:stream_openrouter, llm_model, [], [], nil) { |chunk| }
        end
        
        # 429 rate limit errors are NOT retried (user should wait or upgrade)
        assert_equal 1, call_count, "429 rate limit errors should NOT be retried"
      ensure
        Faraday.define_singleton_method(:new, original_new)
      end
    end
  end
end
