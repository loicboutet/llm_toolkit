module LlmToolkit
  class LlmProvider < ApplicationRecord
    module OpenrouterHandler
      extend ActiveSupport::Concern
      
      private
      
      def call_openrouter(llm_model, system_messages, conversation_history, tools = nil)
        client = Faraday.new(url: 'https://openrouter.ai/api/v1') do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
          f.options.timeout = 300
          f.options.open_timeout = 10
        end

        # Format system messages for OpenRouter
        formatted_system_messages = format_system_messages_for_openrouter(system_messages)

        # Fix the nested content structure for conversation history
        # This also applies cache_control to the last non-tool message
        fixed_conversation_history = fix_conversation_history_for_openrouter(conversation_history)

        # Combine system messages and conversation history
        messages = formatted_system_messages + fixed_conversation_history

        # Use the model_id for API calls, not the display name
        model_name = llm_model.model_id.presence || llm_model.name
        max_tokens = settings&.dig('max_tokens') || LlmToolkit.config.default_max_tokens
        Rails.logger.info("Using model: #{model_name}")
        Rails.logger.info("Max tokens : #{max_tokens}")

        request_body = {
          model: model_name,
          messages: messages,
          stream: false,
        #  max_tokens: max_tokens,
          usage: { include: true }
        }

        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_openrouter(tools)
        end

        Rails.logger.info("OpenRouter Request - Messages count: #{messages.size}")
        Rails.logger.info("OpenRouter Request - System messages: #{formatted_system_messages.size}")
        Rails.logger.info("OpenRouter Request - Tools: #{request_body[:tools]&.size || 0}")
        
        # Log system message structure for debugging
        formatted_system_messages.each_with_index do |msg, idx|
          Rails.logger.info("System message #{idx + 1}: #{msg[:content].size} content parts")
          msg[:content].each_with_index do |content, content_idx|
            if content[:type] == 'file'
              Rails.logger.info("  Content #{content_idx + 1}: file (#{content[:file][:filename]})")
            else
              has_cache = content[:cache_control].present? ? " [CACHED]" : ""
              Rails.logger.info("  Content #{content_idx + 1}: #{content[:type]} (#{content[:text]&.length || 0} chars)#{has_cache}")
            end
          end
        end
        
        # Log conversation history caching info
        log_conversation_caching_info(fixed_conversation_history)
        
        # Detailed request logging
        if Rails.env.development?
          # Don't log full base64 content, just structure
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
          standardize_openrouter_response(response.body)
        else
          Rails.logger.error("OpenRouter API error: #{response.body}")
          raise ApiError, "API error: #{response.body['error']&.[]('message') || response.body}"
        end
      rescue Faraday::Error => e
        Rails.logger.error("OpenRouter API error: #{e.message}")
        raise ApiError, "Network error: #{e.message}"
      end

      def stream_openrouter(llm_model, system_messages, conversation_history, tools = nil, &block)
        # Setup client with read_timeout increased for streaming
        client = Faraday.new(url: 'https://openrouter.ai/api/v1') do |f|
          f.request :json
          # Don't use f.response :json as we need the raw response for streaming
          f.adapter Faraday.default_adapter
          f.options.timeout = 600 # Longer timeout for streaming
          f.options.open_timeout = 10
        end

        # Format system messages for OpenRouter
        formatted_system_messages = format_system_messages_for_openrouter(system_messages)

        # Fix the nested content structure for conversation history
        # This also applies cache_control to the last non-tool message
        fixed_conversation_history = fix_conversation_history_for_openrouter(conversation_history)

        # Combine system messages and conversation history
        messages = formatted_system_messages + fixed_conversation_history

        # Use the model_id for API calls, not the display name
        model_name = llm_model.model_id.presence || llm_model.name
        Rails.logger.info("Using model: #{model_name}")

        request_body = {
          model: model_name,
          messages: messages,
          stream: true,
          usage: { include: true }
        }

        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_openrouter(tools)
        end

        Rails.logger.info("OpenRouter Streaming Request - Messages count: #{messages.size}")
        Rails.logger.info("OpenRouter Streaming Request - System messages: #{formatted_system_messages.size}")
        Rails.logger.info("OpenRouter Streaming Request - Tools count: #{request_body[:tools]&.size || 0}")
        
        # Log system message structure for debugging (including cache info)
        formatted_system_messages.each_with_index do |msg, idx|
          Rails.logger.info("System message #{idx + 1}: #{msg[:content].size} content parts")
          msg[:content].each_with_index do |content, content_idx|
            if content[:type] == 'file'
              Rails.logger.info("  Content #{content_idx + 1}: file (#{content[:file][:filename]})")
            else
              has_cache = content[:cache_control].present? ? " [CACHE_CONTROL: ephemeral]" : ""
              Rails.logger.info("  Content #{content_idx + 1}: #{content[:type]} (#{content[:text]&.length || 0} chars)#{has_cache}")
            end
          end
        end
        
        # Log conversation history caching info
        log_conversation_caching_info(fixed_conversation_history)
        
        # Detailed request logging
        if Rails.env.development?
          sanitized_body = sanitize_request_body_for_logging(request_body)
          Rails.logger.debug "OPENROUTER STREAMING REQUEST BODY: #{JSON.pretty_generate(sanitized_body)}"
        end

        # Initialize variables to track the streaming response
        streaming_state = {
          accumulated_content: "",
          tool_calls: [],
          model_name: nil,
          usage_info: nil,
          content_complete: false,
          finish_reason: nil,
          json_buffer: "",
          generation_id: nil,  # Track generation ID for cache stats
          api_error: nil       # Track API errors from streaming
        }

        response = client.post('chat/completions') do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Authorization'] = "Bearer #{api_key}"
          req.headers['X-Title'] = 'Development Environment'
          req.body = request_body.to_json
          req.options.on_data = proc do |chunk, size, env|
            # Handle streaming response processing with improved buffering
            handle_streaming_chunk_with_buffering(chunk, streaming_state, &block)
          end
        end
        
        # Process any remaining data in the buffer after streaming completes
        # This ensures we capture usage data that may arrive in the final chunk
        process_remaining_buffer(streaming_state, &block)
        
        # Verify response code and return final result
        unless (200..299).cover?(response.status)
          error_detail = streaming_state[:api_error] || "Status #{response.status}"
          Rails.logger.error("OpenRouter API streaming error: #{error_detail}")
          raise ApiError, "API streaming error: #{error_detail}"
        end
        
        # Format the final result
        formatted_tool_calls = format_tools_response_from_openrouter(streaming_state[:tool_calls]) if streaming_state[:tool_calls].any?
        
        # Log final usage info for debugging (including cache stats)
        log_final_usage_stats(streaming_state)
        
        # Return the complete response object
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
      rescue Faraday::Error => e
        Rails.logger.error("OpenRouter API streaming error: #{e.message}")
        raise ApiError, "Network error during streaming: #{e.message}"
      end
      
      private
      
      # Log final usage statistics including cache information
      def log_final_usage_stats(streaming_state)
        usage = streaming_state[:usage_info]
        
        Rails.logger.info("STREAMING COMPLETE - Final usage_info: #{usage.inspect}")
        
        return unless usage
        
        # Log cache-specific stats if present
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
      
      # Log caching information for conversation history messages
      def log_conversation_caching_info(conversation_history)
        cached_count = 0
        total_cached_chars = 0
        
        conversation_history.each do |msg|
          next unless msg[:content].is_a?(Array)
          
          msg[:content].each do |content_item|
            if content_item[:cache_control].present?
              cached_count += 1
              total_cached_chars += content_item[:text]&.length.to_i
            end
          end
        end
        
        if cached_count > 0
          Rails.logger.info("[CONVERSATION CACHE] Applied cache_control to #{cached_count} message(s) (#{total_cached_chars} total chars)")
        end
      end
      
      # Fix conversation history for OpenRouter API compatibility
      # - Converts array content to string for simple text messages
      # - Applies cache_control ONLY to the LAST user/assistant message (NOT tool messages)
      # - Ensures nil content becomes empty string (some models like o4-mini reject null)
      # - Preserves tool_calls structure
      #
      # IMPORTANT: Tool messages MUST have string content, not array content.
      # The Anthropic API (via OpenRouter) rejects tool messages with array content.
      #
      # Note: Anthropic limits to 4 cache_control blocks max. System messages use 1,
      # so we only apply 1 cache_control in conversation (to the last cacheable message).
      def fix_conversation_history_for_openrouter(conversation_history)
        messages = Array(conversation_history)
        return [] if messages.empty?
        
        # Find the last message that CAN have cache_control applied
        # Tool messages cannot have array content, so skip them for caching
        last_cacheable_index = messages.rindex { |msg| msg[:role] != 'tool' }
        
        messages.each_with_index.map do |msg, index|
          fixed_msg = msg.dup
          is_last_cacheable = (index == last_cacheable_index)
          is_tool_message = (msg[:role] == 'tool')
          
          # CRITICAL: Tool messages must ALWAYS have string content
          # Never convert tool message content to array format
          if is_tool_message
            # Ensure tool message content is a string
            if msg[:content].is_a?(Array)
              # Extract text from array format
              text_content = msg[:content].map { |item| item[:text] || item['text'] }.compact.join("\n")
              fixed_msg[:content] = text_content
            elsif msg[:content].nil?
              fixed_msg[:content] = ""
            end
            # String content stays as-is for tool messages
            next fixed_msg
          end
          
          # Handle content formatting for non-tool messages (user/assistant)
          if msg[:content].is_a?(Array) && msg[:content].all? { |item| item.is_a?(Hash) && (item[:type] || item['type']) && (item[:text] || item['text']) }
            # Content is already in array format - extract text
            text_content = msg[:content].map { |item| item[:text] || item['text'] }.join("\n")
            
            # Apply cache_control only to the last cacheable message
            if is_last_cacheable && conversation_caching_enabled?
              fixed_msg[:content] = [
                { type: 'text', text: text_content, cache_control: { type: 'ephemeral' } }
              ]
              Rails.logger.info("[CONVERSATION CACHE] Applied cache_control to last message (#{msg[:role]}, #{text_content.length} chars)")
            else
              fixed_msg[:content] = text_content
            end
          elsif msg[:content].nil?
            # CRITICAL FIX: Convert nil content to empty string
            # Some models (o4-mini via OpenRouter) reject null content in assistant messages
            fixed_msg[:content] = ""
          elsif msg[:content].is_a?(String)
            # String content - apply cache_control only to the last cacheable message
            if is_last_cacheable && conversation_caching_enabled?
              fixed_msg[:content] = [
                { type: 'text', text: msg[:content], cache_control: { type: 'ephemeral' } }
              ]
              Rails.logger.info("[CONVERSATION CACHE] Applied cache_control to last message (#{msg[:role]}, #{msg[:content].length} chars)")
            end
            # Otherwise keep as string (no change needed)
          end
          
          # Ensure tool_calls is preserved if present
          # This handles assistant messages that have tool_calls
          if msg[:tool_calls].present?
            fixed_msg[:tool_calls] = msg[:tool_calls]
          end
          
          fixed_msg
        end
      end
      
      # Check if conversation caching is enabled
      # Uses the same setting as system message caching
      def conversation_caching_enabled?
        LlmToolkit.config.enable_prompt_caching
      end
      
      # Sanitize request body for logging by removing large base64 content
      def sanitize_request_body_for_logging(request_body)
        sanitized = request_body.deep_dup
        
        sanitized[:messages]&.each do |message|
          next unless message[:content].is_a?(Array)
          
          message[:content].each do |content_item|
            if content_item[:type] == 'file' && content_item[:file][:file_data]
              # Replace large base64 content with placeholder
              file_data = content_item[:file][:file_data]
              if file_data.length > 100
                content_item[:file][:file_data] = "#{file_data[0..50]}... [TRUNCATED #{file_data.length} chars]"
              end
            end
            
            # Also truncate large text content for logging
            if content_item[:type] == 'text' && content_item[:text]&.length.to_i > 500
              original_length = content_item[:text].length
              content_item[:text] = "#{content_item[:text][0..200]}... [TRUNCATED #{original_length} chars]"
              # Preserve cache_control info in log
              if content_item[:cache_control]
                content_item[:text] += " [HAS CACHE_CONTROL]"
              end
            end
          end
        end
        
        sanitized
      end
      
      # Improved chunk handling with proper JSON buffering
      def handle_streaming_chunk_with_buffering(chunk, streaming_state, &block)
        # Force chunk encoding to UTF-8 to prevent Encoding::CompatibilityError
        chunk.force_encoding('UTF-8')
        return if chunk.strip.empty?
        
        # Add the new chunk to our buffer
        streaming_state[:json_buffer] << chunk
        
        # Process complete lines from the buffer
        while streaming_state[:json_buffer].include?("\n")
          line, streaming_state[:json_buffer] = streaming_state[:json_buffer].split("\n", 2)
          process_sse_line(line.strip, streaming_state, &block)
        end
      end
      
      # Process any remaining data in the buffer after streaming completes
      # This is important because the usage data chunk may not end with a newline
      def process_remaining_buffer(streaming_state, &block)
        remaining = streaming_state[:json_buffer].strip
        return if remaining.empty?
        
        Rails.logger.info("Processing remaining buffer: #{remaining[0..500]}...")
        
        # Process any remaining lines
        remaining.split("\n").each do |line|
          process_sse_line(line.strip, streaming_state, &block)
        end
        
        # Clear the buffer
        streaming_state[:json_buffer] = ""
      end
      
      # Process a single Server-Sent Events line
      def process_sse_line(line, streaming_state, &block)
        return if line.empty? || line.start_with?(':')
        
        # Check for [DONE] marker
        if line == 'data: [DONE]'
          streaming_state[:content_complete] = true
          return
        end
        
        # Skip if this isn't a data line
        return unless line.start_with?('data: ')
        
        # Extract the JSON part from the SSE line
        json_str = line.sub(/^data: /, '')
        
        begin
          # Parse the chunk JSON
          json_data = JSON.parse(json_str)
          Rails.logger.debug("OpenRouter chunk: #{json_data.inspect}")

          # Check if this chunk contains an error - IMPROVED ERROR HANDLING
          if json_data['error'].present?
            error_obj = json_data['error']
            error_message = error_obj['message'] || error_obj.to_s
            error_code = error_obj['code']
            
            # Extract more detailed error info if available (nested errors from providers)
            if error_obj['metadata'].is_a?(Hash)
              raw_error = error_obj['metadata']['raw']
              if raw_error.present?
                # Try to parse the raw error for more details
                begin
                  raw_parsed = JSON.parse(raw_error.to_s)
                  if raw_parsed.dig('error', 'message')
                    error_message = raw_parsed['error']['message']
                  end
                rescue JSON::ParserError
                  # Keep original message if raw can't be parsed
                end
              end
            end
            
            Rails.logger.error("[OPENROUTER API ERROR] Code: #{error_code}, Message: #{error_message}")
            
            # Store the error for later (in case we need to raise it)
            streaming_state[:api_error] = error_message
            
            # Create user-friendly message for common errors
            friendly_message = translate_api_error_to_friendly_message(error_message, error_code)
            
            # Yield an error chunk with BOTH the friendly message AND the raw error
            yield({ 
              chunk_type: 'error', 
              error_message: friendly_message,
              raw_error: error_message,
              error_code: error_code
            }) if block_given?
            return
          end

          # Process the streaming response
          process_streaming_response_chunk(json_data, streaming_state, &block)
          
        rescue JSON::ParserError => e
          Rails.logger.error("Failed to parse streaming chunk: #{e.message}, chunk: #{json_str[0..200]}...")
          # Don't re-raise, just log and continue - this is common with incomplete chunks
        end
      end
      
      # Translate API error messages to user-friendly French messages
      # Also preserves technical details for debugging
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
          # Extract specific Anthropic error details
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
          # Default: show truncated error message
          "Erreur API: #{error_message.truncate(200)}"
        end
      end
      
      # Legacy method for backward compatibility - delegates to new buffering method
      def handle_streaming_chunk(chunk, accumulated_content, tool_calls, model_name, usage_info, content_complete, finish_reason, &block)
        # Create a temporary streaming state for this method
        streaming_state = {
          accumulated_content: accumulated_content,
          tool_calls: tool_calls,
          model_name: model_name,
          usage_info: usage_info,
          content_complete: content_complete,
          finish_reason: finish_reason,
          json_buffer: ""
        }
        
        handle_streaming_chunk_with_buffering(chunk, streaming_state, &block)
        
        # Update the original variables (this is a bit hacky but maintains backward compatibility)
        accumulated_content.replace(streaming_state[:accumulated_content])
        tool_calls.replace(streaming_state[:tool_calls])
        model_name = streaming_state[:model_name]
        usage_info = streaming_state[:usage_info]
        content_complete = streaming_state[:content_complete]
        finish_reason = streaming_state[:finish_reason]
      end
      
      # Process individual streaming response chunks
      # OpenRouter sends usage data in a final chunk with an empty choices array
      def process_streaming_response_chunk(json_data, streaming_state, &block)
        # Record model name if not yet set
        streaming_state[:model_name] ||= json_data['model']
        
        # Capture generation ID for potential cache stats lookup
        streaming_state[:generation_id] ||= json_data['id']
        
        # IMPORTANT: Capture usage data FIRST, before checking choices
        # OpenRouter sends usage in a separate final chunk with empty choices array:
        # {"id":"gen-xxx","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}
        #
        # For cached requests, usage may also include:
        # - cache_creation_input_tokens: tokens written to cache
        # - cache_read_input_tokens: tokens read from cache (discounted)
        if json_data['usage'].present?
          streaming_state[:usage_info] = json_data['usage']
          
          # Log cache tokens if present
          cache_info = extract_cache_info_from_usage(json_data['usage'])
          if cache_info[:has_cache_data]
            Rails.logger.info("[OPENROUTER STREAM] Cache data received: " \
                              "creation=#{cache_info[:creation]}, read=#{cache_info[:read]}")
          end
          
          Rails.logger.info("CAPTURED USAGE DATA: #{json_data['usage'].inspect}")
        end
        
        # Check if this is a chunk with choices (content or tool calls)
        first_choice = json_data['choices']&.first
        
        # Return early ONLY if there are no choices AND no usage data
        # This allows usage-only chunks (empty choices) to be processed above
        return unless first_choice
        
        # Check for delta for text content
        if first_choice['delta'] && first_choice['delta']['content']
          new_content = first_choice['delta']['content']
          streaming_state[:accumulated_content] += new_content
          
          # Pass the new content to the block
          yield({ chunk_type: 'content', content: new_content }) if block_given?
        end
        
        # Check for a tool call in the delta
        if first_choice['delta'] && first_choice['delta']['tool_calls']
          new_tool_calls = first_choice['delta']['tool_calls']
          
          # Process the tool call (keeping existing complex logic)
          process_tool_calls(new_tool_calls, streaming_state[:tool_calls], &block)
        end
        
        # Check for finish_reason (signals end of content or tool call)
        if first_choice['finish_reason']
          streaming_state[:content_complete] = true
          streaming_state[:finish_reason] = first_choice['finish_reason']
          
          # If we have a non-nil finish reason, the response is complete
          yield({ chunk_type: 'finish', finish_reason: streaming_state[:finish_reason] }) if block_given?
        end
      end
      
      # Extract cache information from usage data
      # Handles multiple formats from different providers via OpenRouter
      # @param usage [Hash] The usage data from OpenRouter
      # @return [Hash] Cache information with :creation, :read, :has_cache_data keys
      def extract_cache_info_from_usage(usage)
        return { creation: 0, read: 0, has_cache_data: false } unless usage
        
        creation = 0
        read = 0
        
        # OpenRouter/Anthropic format (most common)
        creation = usage['cache_creation_input_tokens'].to_i if usage['cache_creation_input_tokens']
        creation = usage['cache_write_input_tokens'].to_i if creation == 0 && usage['cache_write_input_tokens']
        
        read = usage['cache_read_input_tokens'].to_i if usage['cache_read_input_tokens']
        read = usage['cached_tokens'].to_i if read == 0 && usage['cached_tokens']
        
        # Some providers use prompt_tokens_details (nested format)
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
      
      # Process tool calls from streaming response
      def process_tool_calls(new_tool_calls, tool_calls, &block)
        new_tool_calls.each do |tool_call|
          # Find existing tool call or create a new entry
          existing_index = tool_call['index']
          existing_tool_call = nil
          
          # First try to find by ID
          if tool_call['id']
            existing_tool_call = tool_calls.find { |tc| tc['id'] == tool_call['id'] }
          end
          
          # If no matching ID found, try to find by index
          if existing_tool_call.nil? && existing_index.is_a?(Integer)
            existing_tool_call = tool_calls.find { |tc| tc['index'] == existing_index }
          end
          
          if existing_tool_call
            # Update the existing tool call
            update_existing_tool_call(existing_tool_call, tool_call)
          else
            # Create a new tool call entry
            new_entry = create_new_tool_call_entry(tool_call, existing_index)
            tool_calls << new_entry
          end
        end
        
        # Signal that we have a tool call update
        yield({ chunk_type: 'tool_call_update', tool_calls: tool_calls }) if block_given?
      end
      
      # Update existing tool call with new data
      def update_existing_tool_call(existing_tool_call, tool_call)
        # Copy ID if provided
        existing_tool_call['id'] = tool_call['id'] if tool_call['id']
                       
        # Update function data
        if tool_call['function']
          existing_tool_call['function'] ||= {}
          
          # Update the function name if present
          if tool_call['function']['name']
            existing_tool_call['function']['name'] = tool_call['function']['name']
          end
          
          # Concatenate or initialize arguments
          if tool_call['function']['arguments']
            existing_tool_call['function']['arguments'] ||= ''
            existing_tool_call['function']['arguments'] += tool_call['function']['arguments']
          end
        end
      end
      
      # Create new tool call entry
      def create_new_tool_call_entry(tool_call, existing_index)
        new_entry = {
          'index' => existing_index,
          'type' => tool_call['type'] || 'function'
        }
        
        # Add ID if present
        new_entry['id'] = tool_call['id'] if tool_call['id']
        
        # Add function data if present
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
