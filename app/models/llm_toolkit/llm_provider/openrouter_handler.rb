module LlmToolkit
  class LlmProvider < ApplicationRecord
    module OpenrouterHandler
      extend ActiveSupport::Concern
      
      # Safety margin to leave room for model overhead (tool definitions, etc.)
      CONTEXT_SAFETY_MARGIN = 10_000
      
      private
      
      # Calculate appropriate max_tokens based on model type and context usage
      # 
      # OpenAI models: Need explicit max_tokens, calculated based on remaining context
      # Anthropic models: Handle max_tokens automatically, we don't specify it
      # Other models: Use default behavior
      #
      # @param llm_model [LlmToolkit::LlmModel] The model being used
      # @param messages [Array] The formatted messages (to estimate token count)
      # @return [Integer, nil] max_tokens value, or nil to let the model decide
      def calculate_max_tokens_for_model(llm_model, messages)
        model_id = llm_model.model_id.to_s.downcase
        
        # Anthropic models handle max_tokens automatically - don't specify it
        # This allows them to use the full remaining context
        if model_id.start_with?('anthropic/')
          Rails.logger.info("Anthropic model detected - letting model manage max_tokens automatically")
          return nil
        end
        
        # For OpenAI and other models, we need to specify max_tokens
        # Calculate based on remaining context space
        
        # Get configured limits
        output_limit = llm_model.output_token_limit.to_i
        output_limit = LlmToolkit.config.default_max_tokens if output_limit <= 0
        
        context_limit = llm_model.input_token_limit.to_i
        
        # If we don't know the context limit, just use the output limit
        if context_limit <= 0
          Rails.logger.info("No context limit known - using output limit: #{output_limit}")
          return output_limit
        end
        
        # Estimate current prompt size (rough: 4 chars ≈ 1 token)
        prompt_chars = messages.to_json.length
        estimated_prompt_tokens = (prompt_chars / 4.0).ceil
        
        # Calculate remaining space for output
        remaining_tokens = context_limit - estimated_prompt_tokens - CONTEXT_SAFETY_MARGIN
        
        # Use the smaller of: output limit or remaining space
        calculated_max = [output_limit, remaining_tokens].min
        
        # Ensure we have at least some tokens for output (minimum 1000)
        final_max = [calculated_max, 1000].max
        
        if remaining_tokens < output_limit
          Rails.logger.info("Context constraint: #{estimated_prompt_tokens} prompt tokens, #{remaining_tokens} remaining, capped to #{final_max}")
        end
        
        final_max
      end
      
      def call_openrouter(llm_model, system_messages, conversation_history, tools = nil)
        client = Faraday.new(url: 'https://openrouter.ai/api/v1') do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
          f.options.timeout = 300
          f.options.open_timeout = 10
        end

        formatted_system_messages = format_system_messages_for_openrouter(system_messages)
        fixed_conversation_history = fix_conversation_history_for_openrouter(conversation_history)
        messages = formatted_system_messages + fixed_conversation_history

        model_name = llm_model.model_id.presence || llm_model.name
        Rails.logger.info("Using model: #{model_name}")
        
        # Determine max_tokens based on model type
        max_tokens = calculate_max_tokens_for_model(llm_model, messages)
        Rails.logger.info("Max output tokens: #{max_tokens || 'not specified (model default)'}")

        request_body = {
          model: model_name,
          messages: messages,
          stream: false,
          usage: { include: true }
        }
        
        # Only include max_tokens if we have a value (some models handle it automatically)
        request_body[:max_tokens] = max_tokens if max_tokens

        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_openrouter(tools)
        end

        Rails.logger.info("OpenRouter Request - Messages count: #{messages.size}")
        Rails.logger.info("OpenRouter Request - System messages: #{formatted_system_messages.size}")
        Rails.logger.info("OpenRouter Request - Tools: #{request_body[:tools]&.size || 0}")
        
        log_system_message_structure(formatted_system_messages)
        log_conversation_caching_info(fixed_conversation_history)
        
        if Rails.env.development?
          sanitized_body = sanitize_request_body_for_logging(request_body)
          Rails.logger.debug "OPENROUTER REQUEST BODY: #{JSON.pretty_generate(sanitized_body)}"
        end

        response = client.post('chat/completions') do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Authorization'] = "Bearer #{api_key}"
          req.headers['HTTP-Referer'] = LlmToolkit.config.referer_url
          req.headers['X-Title'] = 'Development Environment'
          req.body = request_body.to_json
        end

        if response.success?
          Rails.logger.info("LlmProvider - Received successful response from OpenRouter API:")
          Rails.logger.info(response.body)
          log_cache_stats_from_response(response.body)
          standardize_openrouter_response(response.body)
        else
          Rails.logger.error("OpenRouter API error: #{response.body}")
          
          # Track non-streaming API errors
          NexraiErrorTracker.capture_message(
            "OpenRouter API error (non-streaming)",
            level: :error,
            context: {
              provider: 'openrouter',
              model: model_name,
              status_code: response.status,
              error_body: response.body.to_s.truncate(500),
              messages_count: messages.size,
              tools_count: request_body[:tools]&.size || 0
            }
          )
          
          raise ApiError, "API error: #{response.body['error']&.[]('message') || response.body}"
        end
      rescue Faraday::Error => e
        Rails.logger.error("OpenRouter API error: #{e.message}")
        
        # Track network errors for non-streaming calls
        NexraiErrorTracker.capture_exception(
          e,
          context: {
            provider: 'openrouter',
            model: model_name,
            error_type: 'network_error',
            messages_count: messages.size,
            tools_count: request_body[:tools]&.size || 0
          }
        )
        
        raise ApiError, "Network error: #{e.message}"
      end

      # Retry configuration for transient errors
      STREAMING_MAX_RETRIES = 3
      STREAMING_RETRY_BASE_DELAY = 1.0 # seconds
      STREAMING_RETRY_MAX_DELAY = 8.0 # seconds
      
      # HTTP status codes that should trigger a retry
      RETRYABLE_STATUS_CODES = [500, 502, 503, 504, 520, 521, 522, 523, 524, 529].freeze
      
      def stream_openrouter(llm_model, system_messages, conversation_history, tools = nil, &block)
        formatted_system_messages = format_system_messages_for_openrouter(system_messages)
        fixed_conversation_history = fix_conversation_history_for_openrouter(conversation_history)
        messages = formatted_system_messages + fixed_conversation_history

        model_name = llm_model.model_id.presence || llm_model.name
        Rails.logger.info("Using model: #{model_name}")
        
        # Determine max_tokens based on model type
        max_tokens = calculate_max_tokens_for_model(llm_model, messages)
        Rails.logger.info("Max output tokens: #{max_tokens || 'not specified (model default)'}")

        request_body = {
          model: model_name,
          messages: messages,
          stream: true,
          usage: { include: true }
        }
        
        # Only include max_tokens if we have a value (some models handle it automatically)
        request_body[:max_tokens] = max_tokens if max_tokens

        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_openrouter(tools)
        end

        Rails.logger.info("OpenRouter Streaming Request - Messages count: #{messages.size}")
        Rails.logger.info("OpenRouter Streaming Request - System messages: #{formatted_system_messages.size}")
        Rails.logger.info("OpenRouter Streaming Request - Tools count: #{request_body[:tools]&.size || 0}")
        
        log_system_message_structure(formatted_system_messages)
        log_conversation_caching_info(fixed_conversation_history)
        
        if Rails.env.development?
          sanitized_body = sanitize_request_body_for_logging(request_body)
          Rails.logger.debug "OPENROUTER STREAMING REQUEST BODY: #{JSON.pretty_generate(sanitized_body)}"
        end

        # Execute with retry logic
        execute_streaming_request_with_retry(
          model_name: model_name,
          request_body: request_body,
          messages_count: messages.size,
          tools_count: request_body[:tools]&.size || 0,
          &block
        )
      end

      # Execute the streaming request with retry logic for transient failures
      #
      # @param model_name [String] The model name for logging
      # @param request_body [Hash] The request body to send
      # @param messages_count [Integer] Number of messages for logging
      # @param tools_count [Integer] Number of tools for logging
      # @param block [Proc] Block to process streaming chunks
      # @return [Hash] The final response
      def execute_streaming_request_with_retry(model_name:, request_body:, messages_count:, tools_count:, &block)
        attempt = 0
        last_error = nil
        last_status = nil
        
        while attempt < STREAMING_MAX_RETRIES
          attempt += 1
          
          begin
            Rails.logger.info("[STREAMING RETRY] Attempt #{attempt}/#{STREAMING_MAX_RETRIES} for model #{model_name}")
            
            result = execute_single_streaming_request(
              model_name: model_name,
              request_body: request_body,
              messages_count: messages_count,
              tools_count: tools_count,
              &block
            )
            
            # Success! Return the result
            if attempt > 1
              Rails.logger.info("[STREAMING RETRY] Succeeded on attempt #{attempt} after #{attempt - 1} retries")
            end
            
            return result
            
          rescue RetryableStreamingError => e
            last_error = e
            last_status = e.status_code
            
            if attempt < STREAMING_MAX_RETRIES
              delay = calculate_retry_delay(attempt)
              Rails.logger.warn("[STREAMING RETRY] Attempt #{attempt} failed with retryable error: #{e.message}. " \
                                "Retrying in #{delay}s...")
              sleep(delay)
            else
              Rails.logger.error("[STREAMING RETRY] All #{STREAMING_MAX_RETRIES} attempts failed. Last error: #{e.message}")
            end
            
          rescue NonRetryableStreamingError => e
            # Don't retry client errors (4xx)
            Rails.logger.error("[STREAMING RETRY] Non-retryable error: #{e.message}")
            
            NexraiErrorTracker.capture_message(
              "API streaming error (non-retryable): #{e.status_code}",
              level: :error,
              context: {
                provider: 'openrouter',
                model: model_name,
                status_code: e.status_code,
                error_detail: e.message,
                messages_count: messages_count,
                tools_count: tools_count
              }
            )
            
            raise ApiError, "API streaming error: #{e.message}"
          end
        end
        
        # All retries exhausted
        NexraiErrorTracker.capture_message(
          "API streaming error after #{STREAMING_MAX_RETRIES} retries",
          level: :error,
          context: {
            provider: 'openrouter',
            model: model_name,
            status_code: last_status,
            error_detail: last_error&.message,
            messages_count: messages_count,
            tools_count: tools_count,
            retry_attempts: STREAMING_MAX_RETRIES
          }
        )
        
        raise ApiError, "API streaming error after #{STREAMING_MAX_RETRIES} retries: #{last_error&.message}"
      end
      
      # Calculate delay for exponential backoff with jitter
      # @param attempt [Integer] Current attempt number (1-based)
      # @return [Float] Delay in seconds
      def calculate_retry_delay(attempt)
        # Exponential backoff: base_delay * 2^(attempt-1)
        delay = STREAMING_RETRY_BASE_DELAY * (2 ** (attempt - 1))
        # Cap at max delay
        delay = [delay, STREAMING_RETRY_MAX_DELAY].min
        # Add jitter (±25%)
        jitter = delay * 0.25 * (rand * 2 - 1)
        delay + jitter
      end
      
      # Internal error class for retryable errors (network issues, 5xx errors)
      class RetryableStreamingError < StandardError
        attr_reader :status_code
        
        def initialize(message, status_code = nil)
          super(message)
          @status_code = status_code
        end
      end
      
      # Internal error class for non-retryable errors (4xx client errors)
      class NonRetryableStreamingError < StandardError
        attr_reader :status_code
        
        def initialize(message, status_code = nil)
          super(message)
          @status_code = status_code
        end
      end
      
      # Execute a single streaming request (without retry logic)
      def execute_single_streaming_request(model_name:, request_body:, messages_count:, tools_count:, &block)
        client = Faraday.new(url: 'https://openrouter.ai/api/v1') do |f|
          f.request :json
          f.adapter Faraday.default_adapter
          f.options.timeout = 600
          f.options.open_timeout = 10
        end

        streaming_state = {
          accumulated_content: "",
          tool_calls: [],
          model_name: nil,
          usage_info: nil,
          content_complete: false,
          finish_reason: nil,
          json_buffer: "",
          generation_id: nil,
          api_error: nil
        }

        response = client.post('chat/completions') do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Authorization'] = "Bearer #{api_key}"
          req.headers['X-Title'] = 'Development Environment'
          req.body = request_body.to_json
          req.options.on_data = proc do |chunk, size, env|
            handle_streaming_chunk_with_buffering(chunk, streaming_state, &block)
          end
        end
        
        process_remaining_buffer(streaming_state, &block)
        
        # Check for error responses
        unless (200..299).cover?(response.status)
          error_detail = streaming_state[:api_error] || "Status #{response.status}"
          
          # Determine if error is retryable
          if RETRYABLE_STATUS_CODES.include?(response.status)
            raise RetryableStreamingError.new(error_detail, response.status)
          else
            raise NonRetryableStreamingError.new(error_detail, response.status)
          end
        end
        
        formatted_tool_calls = format_tools_response_from_openrouter(streaming_state[:tool_calls]) if streaming_state[:tool_calls].any?
        
        log_final_usage_stats(streaming_state)
        
        {
          'content' => streaming_state[:accumulated_content],
          'model' => streaming_state[:model_name],
          'role' => 'assistant',
          'stop_reason' => streaming_state[:content_complete] ? 'stop' : nil,
          'stop_sequence' => nil,
          'tool_calls' => formatted_tool_calls || [],
          'usage' => streaming_state[:usage_info],
          'finish_reason' => streaming_state[:finish_reason],
          'generation_id' => streaming_state[:generation_id]
        }
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError => e
        # Network errors are retryable
        Rails.logger.warn("[STREAMING] Network error: #{e.class.name} - #{e.message}")
        raise RetryableStreamingError.new("Network error: #{e.message}")
        
      rescue Faraday::Error => e
        # Other Faraday errors - check if they might be retryable
        Rails.logger.error("[STREAMING] Faraday error: #{e.class.name} - #{e.message}")
        
        # Default to retryable for unknown Faraday errors
        raise RetryableStreamingError.new("Network error: #{e.message}")
      end
      
      private
      
      def log_system_message_structure(formatted_system_messages)
        formatted_system_messages.each_with_index do |msg, idx|
          Rails.logger.info("System message #{idx + 1}: #{msg[:content].size} content parts")
          msg[:content].each_with_index do |content, content_idx|
            if content[:type] == 'file'
              Rails.logger.info("  Content #{content_idx + 1}: file (#{content[:file][:filename]})")
            else
              has_cache = content[:cache_control].present? ? " [CACHE_CONTROL]" : ""
              Rails.logger.info("  Content #{content_idx + 1}: #{content[:type]} (#{content[:text]&.length || 0} chars)#{has_cache}")
            end
          end
        end
      end
      
      def log_cache_stats_from_response(response_body)
        usage = response_body['usage']
        return unless usage
        
        cache_info = extract_cache_info_from_usage(usage)
        prompt_tokens = usage['prompt_tokens'].to_i
        
        if cache_info[:has_cache_data]
          hit_rate = prompt_tokens > 0 ? ((cache_info[:read].to_f / prompt_tokens) * 100).round(1) : 0
          Rails.logger.info("[OPENROUTER CACHE] Response cache stats:")
          Rails.logger.info("  - Prompt tokens: #{prompt_tokens}")
          Rails.logger.info("  - Cache creation tokens: #{cache_info[:creation]}")
          Rails.logger.info("  - Cache read tokens: #{cache_info[:read]}")
          Rails.logger.info("  - Cache hit rate: #{hit_rate}%")
        else
          Rails.logger.info("[OPENROUTER CACHE] No cache data in response (prompt_tokens: #{prompt_tokens})")
        end
      end
      
      def log_final_usage_stats(streaming_state)
        usage = streaming_state[:usage_info]
        
        Rails.logger.info("STREAMING COMPLETE - Final usage_info: #{usage.inspect}")
        
        return unless usage
        
        cache_info = extract_cache_info_from_usage(usage)
        
        if cache_info[:has_cache_data]
          Rails.logger.info("[OPENROUTER CACHE] Streaming response cache stats:")
          Rails.logger.info("  - Cache creation tokens: #{cache_info[:creation]}")
          Rails.logger.info("  - Cache read tokens: #{cache_info[:read]}")
          
          prompt_tokens = usage['prompt_tokens'].to_i
          if prompt_tokens > 0 && cache_info[:read] > 0
            hit_rate = ((cache_info[:read].to_f / prompt_tokens) * 100).round(1)
            Rails.logger.info("  - Cache hit rate: #{hit_rate}%")
          end
        end
      end
      
      def log_conversation_caching_info(conversation_history)
        cached_count = 0
        total_cached_chars = 0
        cached_positions = []
        tool_message_count = 0
        
        conversation_history.each_with_index do |msg, idx|
          tool_message_count += 1 if msg[:role] == 'tool'
          
          next unless msg[:content].is_a?(Array)
          
          msg[:content].each do |content_item|
            if content_item[:cache_control].present?
              cached_count += 1
              total_cached_chars += content_item[:text]&.length.to_i
              cached_positions << "msg[#{idx}] (#{msg[:role]})"
            end
          end
        end
        
        if cached_count > 0
          Rails.logger.info("[CONVERSATION CACHE] Applied cache_control to #{cached_count} block(s) at: #{cached_positions.join(', ')}")
          Rails.logger.info("[CONVERSATION CACHE] Total chars in cached messages: #{total_cached_chars}")
        else
          Rails.logger.info("[CONVERSATION CACHE] No cache_control applied to conversation history")
        end
        
        if tool_message_count > 0
          Rails.logger.info("[CONVERSATION CACHE] Tool messages in history: #{tool_message_count}")
        end
      end
      
      # Fix conversation history for OpenRouter API compatibility
      #
      # CACHING STRATEGY FOR TOOL-HEAVY CONVERSATIONS:
      # 
      # Key insight: Tool messages CAN have array content with cache_control!
      # This was verified via real API testing (contrary to earlier assumptions).
      #
      # Strategy:
      # 1. First user message (stable anchor)
      # 2. Last tool message with content (caches large tool results directly)
      # 3. Last non-tool message with content (fallback for non-tool conversations)
      #
      # This ensures tool results get cached efficiently.
      def fix_conversation_history_for_openrouter(conversation_history)
        messages = Array(conversation_history)
        return [] if messages.empty?
        
        # Find cache breakpoint indices (now includes tool messages!)
        cache_indices = find_cache_breakpoint_indices(messages)
        
        Rails.logger.info("[CONVERSATION CACHE] Strategy: first_user + last_tool_or_content")
        Rails.logger.info("[CONVERSATION CACHE] Cache breakpoints at indices: #{cache_indices.inspect}")
        
        messages.each_with_index.map do |msg, index|
          fixed_msg = msg.dup
          is_tool_message = (msg[:role] == 'tool')
          should_cache = cache_indices.include?(index) && conversation_caching_enabled?
          
          content = msg[:content]
          
          # Handle tool messages - can now have array content with cache_control!
          if is_tool_message
            if should_cache && content.present?
              # Convert to array format with cache_control
              text_content = ensure_string_content(content)
              fixed_msg[:content] = [
                { type: 'text', text: text_content, cache_control: { type: 'ephemeral' } }
              ]
              Rails.logger.info("[CONVERSATION CACHE] Cache breakpoint at message #{index} (tool, #{text_content.length} chars)")
            else
              # Keep as string for non-cached tool messages
              fixed_msg[:content] = ensure_string_content(content)
            end
            next fixed_msg
          end
          
          # Handle non-tool messages
          if content.nil?
            fixed_msg[:content] = ""
          elsif content.is_a?(String)
            if should_cache && content.present?
              fixed_msg[:content] = [
                { type: 'text', text: content, cache_control: { type: 'ephemeral' } }
              ]
              Rails.logger.info("[CONVERSATION CACHE] Cache breakpoint at message #{index} (#{msg[:role]}, #{content.length} chars)")
            end
          elsif content.is_a?(Array)
            if should_cache
              fixed_msg[:content] = apply_cache_control_to_last_block(content)
              text_chars = content.sum { |item| get_text_from_item(item)&.length.to_i }
              Rails.logger.info("[CONVERSATION CACHE] Cache breakpoint at message #{index} (#{msg[:role]}, #{text_chars} chars)")
            end
          end
          
          if msg[:tool_calls].present?
            fixed_msg[:tool_calls] = msg[:tool_calls]
          end
          
          fixed_msg
        end
      end
      
      # Find strategic cache breakpoint indices
      #
      # NEW STRATEGY (supports tool message caching):
      #
      # 1. FIRST USER MESSAGE - Stable anchor for [system + first user]
      #
      # 2. LAST TOOL MESSAGE - Tool results are often the largest content!
      #    Cache them directly for maximum efficiency.
      #
      # 3. LAST NON-TOOL MESSAGE WITH CONTENT - Fallback for conversations
      #    without tools or after the last tool.
      #
      # Example:
      #   [0] user "help me"               <- BREAKPOINT 1 (stable)
      #   [1] assistant + tool_calls (empty)
      #   [2] tool result (5000 tokens)    <- BREAKPOINT 2 (tool!)
      #   [3] assistant "here's what I found"
      #   [4] user "thanks"                <- BREAKPOINT 3 (last with content)
      #
      # Find cache breakpoint indices for Anthropic prompt caching.
      #
      # HOW ANTHROPIC CACHING WORKS:
      # - Anthropic caches the PREFIX up to each cache_control marker
      # - To READ a cache, you need a marker at the SAME position as before
      # - To CREATE a new cache, you add a marker at the end
      #
      # CORRECT STRATEGY:
      # 1. First user message - caches [system prompt + first user message]
      # 2. Second-to-last message - READ point (matches last turn's creation point)
      # 3. Last message - CREATE point (for next turn to read)
      #
      # This ensures that:
      # - Turn N creates cache at position X (last message)
      # - Turn N+1 reads cache at position X (now second-to-last) ✓ MATCH!
      # - Turn N+1 creates new cache at position X+1 (new last message)
      #
      def find_cache_breakpoint_indices(messages)
        return [] if messages.empty?
        
        cache_indices = []
        last_idx = messages.size - 1
        
        # 1. First user message (stable anchor for system prompt caching)
        first_user_idx = messages.index { |m| m[:role] == 'user' }
        cache_indices << first_user_idx if first_user_idx
        
        # 2. Second-to-last message (READ point - matches previous turn's CREATE point)
        if last_idx >= 2
          second_to_last_idx = last_idx - 1
          cache_indices << second_to_last_idx
        end
        
        # 3. Last message (CREATE point - for next turn to read)
        if last_idx >= 1
          cache_indices << last_idx
        end
        
        # Sort, dedupe, and limit to 3 (Anthropic allows 4 total, 1 for system)
        cache_indices = cache_indices.compact.uniq.sort.first(3)
        
        cache_indices
      end
      
      def apply_cache_control_to_last_block(content_array)
        return content_array if content_array.blank?
        
        last_text_index = nil
        content_array.each_with_index do |item, idx|
          item_type = item[:type] || item['type']
          if item_type == 'text'
            last_text_index = idx
          end
        end
        
        last_text_index ||= content_array.size - 1
        
        content_array.each_with_index.map do |item, idx|
          if idx == last_text_index
            item_dup = item.dup
            item_dup[:cache_control] = { type: 'ephemeral' }
            item_dup
          else
            item
          end
        end
      end
      
      def get_text_from_item(item)
        return nil unless item.is_a?(Hash)
        item[:text] || item['text']
      end
      
      def ensure_string_content(content)
        if content.is_a?(Array)
          content.map { |item| get_text_from_item(item) }.compact.join("\n")
        elsif content.nil?
          ""
        else
          content.to_s
        end
      end
      
      def conversation_caching_enabled?
        LlmToolkit.config.enable_prompt_caching
      end
      
      def sanitize_request_body_for_logging(request_body)
        sanitized = request_body.deep_dup
        
        sanitized[:messages]&.each do |message|
          next unless message[:content].is_a?(Array)
          
          message[:content].each do |content_item|
            if content_item[:type] == 'file' && content_item[:file]&.[](:file_data)
              file_data = content_item[:file][:file_data]
              if file_data.length > 100
                content_item[:file][:file_data] = "#{file_data[0..50]}... [TRUNCATED #{file_data.length} chars]"
              end
            end
            
            if content_item[:type] == 'image_url' && content_item[:image_url]&.[](:url)
              url = content_item[:image_url][:url]
              if url.length > 100
                content_item[:image_url][:url] = "#{url[0..50]}... [TRUNCATED #{url.length} chars]"
              end
            end
            
            if content_item[:type] == 'text' && content_item[:text]&.length.to_i > 500
              original_length = content_item[:text].length
              content_item[:text] = "#{content_item[:text][0..200]}... [TRUNCATED #{original_length} chars]"
              if content_item[:cache_control]
                content_item[:text] += " [HAS CACHE_CONTROL]"
              end
            end
          end
        end
        
        sanitized
      end
      
      def handle_streaming_chunk_with_buffering(chunk, streaming_state, &block)
        chunk.force_encoding('UTF-8')
        return if chunk.strip.empty?
        
        streaming_state[:json_buffer] << chunk
        
        while streaming_state[:json_buffer].include?("\n")
          line, streaming_state[:json_buffer] = streaming_state[:json_buffer].split("\n", 2)
          process_sse_line(line.strip, streaming_state, &block)
        end
      end
      
      def process_remaining_buffer(streaming_state, &block)
        remaining = streaming_state[:json_buffer].strip
        return if remaining.empty?
        
        Rails.logger.info("Processing remaining buffer: #{remaining[0..500]}...")
        
        remaining.split("\n").each do |line|
          process_sse_line(line.strip, streaming_state, &block)
        end
        
        streaming_state[:json_buffer] = ""
      end
      
      def process_sse_line(line, streaming_state, &block)
        return if line.empty? || line.start_with?(':')
        
        if line == 'data: [DONE]'
          streaming_state[:content_complete] = true
          return
        end
        
        return unless line.start_with?('data: ')
        
        json_str = line.sub(/^data: /, '')
        
        begin
          json_data = JSON.parse(json_str)
          Rails.logger.debug("OpenRouter chunk: #{json_data.inspect}")

          if json_data['error'].present?
            error_obj = json_data['error']
            error_message = error_obj['message'] || error_obj.to_s
            error_code = error_obj['code']
            
            if error_obj['metadata'].is_a?(Hash)
              raw_error = error_obj['metadata']['raw']
              if raw_error.present?
                begin
                  raw_parsed = JSON.parse(raw_error.to_s)
                  if raw_parsed.dig('error', 'message')
                    error_message = raw_parsed['error']['message']
                  end
                rescue JSON::ParserError
                end
              end
            end
            
            Rails.logger.error("[OPENROUTER API ERROR] Code: #{error_code}, Message: #{error_message}")
            
            # Track API errors for monitoring
            NexraiErrorTracker.capture_message(
              "OpenRouter API error in stream",
              level: :error,
              context: {
                provider: 'openrouter',
                error_code: error_code,
                error_message: error_message,
                model: streaming_state[:model_name]
              }
            )
            
            streaming_state[:api_error] = error_message
            
            friendly_message = translate_api_error_to_friendly_message(error_message, error_code)
            
            yield({ 
              chunk_type: 'error', 
              error_message: friendly_message,
              raw_error: error_message,
              error_code: error_code
            }) if block_given?
            return
          end

          process_streaming_response_chunk(json_data, streaming_state, &block)
          
        rescue JSON::ParserError => e
          Rails.logger.error("Failed to parse streaming chunk: #{e.message}, chunk: #{json_str[0..200]}...")
        end
      end
      
      def translate_api_error_to_friendly_message(error_message, error_code = nil)
        case error_message
        when /no endpoints found that support tool use/i
          "Le modèle sélectionné ne prend pas en charge les outils avancés."
        when /rate limit/i, /too many requests/i
          "Le service est temporairement surchargé. Veuillez réessayer dans quelques instants."
        when /model .* not found/i
          "Le modèle demandé n'est pas disponible. Essayez de sélectionner un autre modèle."
        when /tool_use.*without.*tool_result/i, /tool_result.*tool_use_id/i
          "Erreur de synchronisation des outils. Veuillez réessayer ou démarrer une nouvelle conversation."
        when /invalid_request_error/i
          if error_message =~ /messages\.\d+\.content/
            "Format de message invalide. Veuillez réessayer ou démarrer une nouvelle conversation."
          else
            "Requête invalide: #{error_message.truncate(150)}"
          end
        when /context.*too long/i, /maximum context length/i
          "La conversation est devenue trop longue. Veuillez démarrer une nouvelle conversation."
        when /content.*filter/i, /safety/i
          "Le contenu a été filtré pour des raisons de sécurité."
        when /timeout/i
          "La requête a pris trop de temps. Veuillez réessayer."
        when /authentication/i, /unauthorized/i, /api.?key/i
          "Erreur d'authentification avec le service. Veuillez contacter l'administrateur."
        else
          "Erreur API: #{error_message.truncate(200)}"
        end
      end
      
      def process_streaming_response_chunk(json_data, streaming_state, &block)
        streaming_state[:model_name] ||= json_data['model']
        streaming_state[:generation_id] ||= json_data['id']
        
        if json_data['usage'].present?
          streaming_state[:usage_info] = json_data['usage']
          
          cache_info = extract_cache_info_from_usage(json_data['usage'])
          if cache_info[:has_cache_data]
            Rails.logger.info("[OPENROUTER STREAM] Cache data received: " \
                              "creation=#{cache_info[:creation]}, read=#{cache_info[:read]}")
          end
          
          Rails.logger.info("CAPTURED USAGE DATA: #{json_data['usage'].inspect}")
        end
        
        first_choice = json_data['choices']&.first
        return unless first_choice
        
        if first_choice['delta'] && first_choice['delta']['content']
          new_content = first_choice['delta']['content']
          streaming_state[:accumulated_content] += new_content
          yield({ chunk_type: 'content', content: new_content }) if block_given?
        end
        
        if first_choice['delta'] && first_choice['delta']['tool_calls']
          new_tool_calls = first_choice['delta']['tool_calls']
          process_tool_calls(new_tool_calls, streaming_state[:tool_calls], &block)
        end
        
        if first_choice['finish_reason']
          streaming_state[:content_complete] = true
          streaming_state[:finish_reason] = first_choice['finish_reason']
          yield({ chunk_type: 'finish', finish_reason: streaming_state[:finish_reason] }) if block_given?
        end
      end
      
      def extract_cache_info_from_usage(usage)
        return { creation: 0, read: 0, has_cache_data: false } unless usage
        
        creation = 0
        read = 0
        
        creation = usage['cache_creation_input_tokens'].to_i if usage['cache_creation_input_tokens']
        creation = usage['cache_write_input_tokens'].to_i if creation == 0 && usage['cache_write_input_tokens']
        
        read = usage['cache_read_input_tokens'].to_i if usage['cache_read_input_tokens']
        read = usage['cached_tokens'].to_i if read == 0 && usage['cached_tokens']
        
        if usage['prompt_tokens_details'].is_a?(Hash)
          details = usage['prompt_tokens_details']
          creation = details['cached_tokens_creation'].to_i if creation == 0 && details['cached_tokens_creation']
          read = details['cached_tokens'].to_i if read == 0 && details['cached_tokens']
        end
        
        {
          creation: creation,
          read: read,
          has_cache_data: creation > 0 || read > 0
        }
      end
      
      def process_tool_calls(new_tool_calls, tool_calls, &block)
        new_tool_calls.each do |tool_call|
          existing_index = tool_call['index']
          existing_tool_call = nil
          
          if tool_call['id']
            existing_tool_call = tool_calls.find { |tc| tc['id'] == tool_call['id'] }
          end
          
          if existing_tool_call.nil? && existing_index.is_a?(Integer)
            existing_tool_call = tool_calls.find { |tc| tc['index'] == existing_index }
          end
          
          if existing_tool_call
            update_existing_tool_call(existing_tool_call, tool_call)
          else
            new_entry = create_new_tool_call_entry(tool_call, existing_index)
            tool_calls << new_entry
          end
        end
        
        yield({ chunk_type: 'tool_call_update', tool_calls: tool_calls }) if block_given?
      end
      
      def update_existing_tool_call(existing_tool_call, tool_call)
        existing_tool_call['id'] = tool_call['id'] if tool_call['id']
                       
        if tool_call['function']
          existing_tool_call['function'] ||= {}
          
          if tool_call['function']['name']
            existing_tool_call['function']['name'] = tool_call['function']['name']
          end
          
          if tool_call['function']['arguments']
            existing_tool_call['function']['arguments'] ||= ''
            incoming = tool_call['function']['arguments']
            existing = existing_tool_call['function']['arguments']
            
# FIX: Detect and fix streaming chunk bug where chunks incorrectly duplicate JSON opening
            # Pattern 1: existing is '{"' and incoming starts with '{"' 
            # Pattern 2: existing ends with '{"' and incoming starts with '{"'
            # Pattern 3: existing is just '{' and incoming starts with '{"'
            # This creates malformed JSON like '{"{command' instead of '{"command'
            
            # Debug: Log when we have short existing to understand the pattern
            if existing.length > 0 && existing.length < 20 && incoming.start_with?('{')
              Rails.logger.info("[STREAM_DEBUG] existing=#{existing.inspect} incoming_start=#{incoming[0..30].inspect}")
            end
            
            # Fix pattern 1: existing is exactly '{"'
            if existing.strip == '{"' && incoming.start_with?('{"')
              incoming = incoming[2..-1] || ''
              Rails.logger.warn("[STREAM_FIX] Fixed duplicate JSON opening (pattern 1)")
            # Fix pattern 2: existing ends with '{"' and incoming starts with '{"'
            elsif existing.end_with?('{"') && incoming.start_with?('{"')
              incoming = incoming[2..-1] || ''
              Rails.logger.warn("[STREAM_FIX] Fixed duplicate JSON opening (pattern 2)")
            # Fix pattern 3: existing is just '{' and incoming starts with '{"'
            elsif existing.strip == '{' && incoming.start_with?('{"')
              incoming = incoming[1..-1] || ''
              Rails.logger.warn("[STREAM_FIX] Fixed duplicate JSON opening (pattern 3)")
            end
            
            existing_tool_call['function']['arguments'] += incoming
          end
        end
      end
      
      def create_new_tool_call_entry(tool_call, existing_index)
        new_entry = {
          'index' => existing_index,
          'type' => tool_call['type'] || 'function'
        }
        
        new_entry['id'] = tool_call['id'] if tool_call['id']
        
        if tool_call['function']
          new_entry['function'] = {}
          new_entry['function']['name'] = tool_call['function']['name'] if tool_call['function']['name']
          new_entry['function']['arguments'] = tool_call['function']['arguments'] if tool_call['function']['arguments']
        end
        
        new_entry
      end
    end
  end
end
