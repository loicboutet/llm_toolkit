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
        fixed_conversation_history = Array(conversation_history).map do |msg|
          # If content is an array of objects with 'type' and 'text' properties, convert to string
          if msg[:content].is_a?(Array) && msg[:content].all? { |item| item.is_a?(Hash) && item[:type] && item[:text] }
            # Extract just the text from each content item
            text_content = msg[:content].map { |item| item[:text] }.join("\n")
            msg.merge(content: text_content)
          else
            # Keep as-is if already a string or other format
            msg
          end
        end

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
          usage: {
            include: true
          },
          max_tokens: max_tokens,
          usage: {include: true},
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
              Rails.logger.info("  Content #{content_idx + 1}: #{content[:type]} (#{content[:text]&.length || 0} chars)")
            end
          end
        end
        
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
        fixed_conversation_history = Array(conversation_history).map do |msg|
          # If content is an array of objects with 'type' and 'text' properties, convert to string
          if msg[:content].is_a?(Array) && msg[:content].all? { |item| item.is_a?(Hash) && item[:type] && item[:text] }
            # Extract just the text from each content item
            text_content = msg[:content].map { |item| item[:text] }.join("\n")
            msg.merge(content: text_content)
          else
            # Keep as-is if already a string or other format
            msg
          end
        end

        # Combine system messages and conversation history
        messages = formatted_system_messages + fixed_conversation_history

        # Use the model_id for API calls, not the display name
        model_name = llm_model.model_id.presence || llm_model.name
        Rails.logger.info("Using model: #{model_name}")

        request_body = {
          model: model_name,
          messages: messages,
          stream: true, # Enable streaming
          usage: {
            include: true
          },        }

        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_openrouter(tools)
        end

        Rails.logger.info("OpenRouter Streaming Request - Messages count: #{messages.size}")
        Rails.logger.info("OpenRouter Streaming Request - System messages: #{formatted_system_messages.size}")
        Rails.logger.info("OpenRouter Streaming Request - Tools count: #{request_body[:tools]&.size || 0}")
        
        # Log system message structure for debugging
        formatted_system_messages.each_with_index do |msg, idx|
          Rails.logger.info("System message #{idx + 1}: #{msg[:content].size} content parts")
          msg[:content].each_with_index do |content, content_idx|
            if content[:type] == 'file'
              Rails.logger.info("  Content #{content_idx + 1}: file (#{content[:file][:filename]})")
            else
              Rails.logger.info("  Content #{content_idx + 1}: #{content[:type]} (#{content[:text]&.length || 0} chars)")
            end
          end
        end
        
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
          json_buffer: ""
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
        
        # Verify response code and return final result
        unless (200..299).cover?(response.status)
          Rails.logger.error("OpenRouter API streaming error: Status #{response.status}")
          raise ApiError, "API streaming error: Status #{response.status}"
        end
        
        # Format the final result
        formatted_tool_calls = format_tools_response_from_openrouter(streaming_state[:tool_calls]) if streaming_state[:tool_calls].any?
        
        # Return the complete response object
        {
          'content' => streaming_state[:accumulated_content],
          'model' => streaming_state[:model_name],
          'role' => 'assistant',
          'stop_reason' => streaming_state[:content_complete] ? 'stop' : nil,
          'stop_sequence' => nil,
          'tool_calls' => formatted_tool_calls || [],
          'usage' => streaming_state[:usage_info],
          'finish_reason' => streaming_state[:finish_reason]
        }
      rescue Faraday::Error => e
        Rails.logger.error("OpenRouter API streaming error: #{e.message}")
        raise ApiError, "Network error during streaming: #{e.message}"
      end
      
      private
      
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
          Rails.logger.info("OpenRouter chunk : #{json_data}")

          # Check if this chunk contains an error - SIMPLE ERROR HANDLING
          if json_data['error'].present?
            error_message = json_data['error']['message']
            
            # Create user-friendly message for common errors
            friendly_message = case error_message
            when /no endpoints found that support tool use/i
              "Le modèle sélectionné ne prend pas en charge les outils avancés."
            when /rate limit/i, /too many requests/i
              "Le service est temporairement surchargé. Veuillez réessayer dans quelques instants."
            when /model .* not found/i
              "Le modèle demandé n'est pas disponible. Essayez de sélectionner un autre modèle."
            else
              "Une erreur s'est produite: #{error_message}"
            end
            
            # Yield an error chunk
            yield({ chunk_type: 'error', error_message: friendly_message }) if block_given?
            return
          end

          # Process the streaming response
          process_streaming_response_chunk(json_data, streaming_state, &block)
          
        rescue JSON::ParserError => e
          Rails.logger.error("Failed to parse streaming chunk: #{e.message}, chunk: #{json_str}")
          # Don't re-raise, just log and continue - this is common with incomplete chunks
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
      def process_streaming_response_chunk(json_data, streaming_state, &block)
        # Record model name if not yet set
        streaming_state[:model_name] ||= json_data['model']
        
        # Check if this is a tool call chunk
        first_choice = json_data['choices']&.first
        return unless first_choice
        
        # Record usage if present (typically in the final chunk)
        streaming_state[:usage_info] = json_data['usage'] if json_data['usage']
        
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