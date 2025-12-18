module LlmToolkit
  class LlmProvider < ApplicationRecord
    module AnthropicHandler
      extend ActiveSupport::Concern
      
      private
      
      # Stream chat implementation for Anthropic direct API
      # Uses Server-Sent Events (SSE) for real-time streaming
      # @param llm_model [LlmModel] The model to use
      # @param system_messages [Array<Hash>] System messages for the LLM
      # @param conversation_history [Array<Hash>] Previous messages in the conversation
      # @param tools [Array<Hash>, nil] Tools available for the LLM
      # @yield [Hash] Yields each chunk of the streamed response
      # @return [Hash] Standardized final response from the LLM API stream
      def stream_anthropic(llm_model, system_messages, conversation_history, tools = nil, &block)
        client = Faraday.new(url: 'https://api.anthropic.com') do |f|
          f.request :json
          f.adapter Faraday.default_adapter
          f.options.timeout = 600
          f.options.open_timeout = 10
        end

        tools = Array(tools)
        all_tools = tools.presence || LlmToolkit::ToolService.tool_definitions
        
        model_name = llm_model.model_id.presence || llm_model.name
        max_tokens = settings&.dig('max_tokens').to_i || LlmToolkit.config.default_max_tokens
        
        Rails.logger.info("Anthropic Streaming - Using model: #{model_name}")
        Rails.logger.info("Anthropic Streaming - Max tokens: #{max_tokens}")
        Rails.logger.info("Anthropic Streaming - Tools count: #{all_tools.size}")

        # Format system messages for Anthropic (simple text format)
        system_content = format_system_messages_for_anthropic(system_messages)

        request_body = {
          model: model_name,
          system: system_content,
          messages: conversation_history,
          tools: all_tools,
          max_tokens: max_tokens,
          stream: true
        }
        request_body[:tool_choice] = { type: "auto" } if tools.present?

        Rails.logger.info("Anthropic Streaming - System content length: #{system_content.length}")
        Rails.logger.info("Anthropic Streaming - Conversation history: #{conversation_history.size} messages")

        # Initialize streaming state
        streaming_state = {
          accumulated_content: "",
          tool_calls: [],
          model_name: nil,
          usage_info: nil,
          content_complete: false,
          finish_reason: nil,
          json_buffer: "",
          current_tool_use: nil,
          api_error: nil,
          message_id: nil
        }

        response = client.post('/v1/messages') do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['x-api-key'] = api_key
          req.headers['anthropic-version'] = '2023-06-01'
          req.headers['anthropic-beta'] = 'prompt-caching-2024-07-31'
          req.body = request_body.to_json
          req.options.on_data = proc do |chunk, size, env|
            handle_anthropic_streaming_chunk(chunk, streaming_state, &block)
          end
        end
        
        # Process any remaining buffer
        process_anthropic_remaining_buffer(streaming_state, &block)
        
        unless (200..299).cover?(response.status)
          error_detail = streaming_state[:api_error] || "Status #{response.status}"
          Rails.logger.error("Anthropic API streaming error: #{error_detail}")
          raise ApiError, "Anthropic API streaming error: #{error_detail}"
        end
        
        # Log final usage
        log_anthropic_final_usage(streaming_state)
        
        # Return standardized response
        {
          'content' => streaming_state[:accumulated_content],
          'model' => streaming_state[:model_name] || model_name,
          'role' => 'assistant',
          'stop_reason' => streaming_state[:finish_reason],
          'stop_sequence' => nil,
          'tool_calls' => streaming_state[:tool_calls],
          'usage' => streaming_state[:usage_info],
          'finish_reason' => streaming_state[:finish_reason],
          'message_id' => streaming_state[:message_id]
        }
      rescue Faraday::Error => e
        Rails.logger.error("Anthropic API streaming error: #{e.message}")
        raise ApiError, "Network error during Anthropic streaming: #{e.message}"
      end
      
      private
      
      def handle_anthropic_streaming_chunk(chunk, streaming_state, &block)
        chunk.force_encoding('UTF-8')
        return if chunk.strip.empty?
        
        streaming_state[:json_buffer] << chunk
        
        # Process complete SSE lines
        while streaming_state[:json_buffer].include?("\n")
          line, streaming_state[:json_buffer] = streaming_state[:json_buffer].split("\n", 2)
          process_anthropic_sse_line(line.strip, streaming_state, &block)
        end
      end
      
      def process_anthropic_remaining_buffer(streaming_state, &block)
        remaining = streaming_state[:json_buffer].strip
        return if remaining.empty?
        
        remaining.split("\n").each do |line|
          process_anthropic_sse_line(line.strip, streaming_state, &block)
        end
        
        streaming_state[:json_buffer] = ""
      end
      
      def process_anthropic_sse_line(line, streaming_state, &block)
        return if line.empty? || line.start_with?(':')
        
        # Handle event type line
        if line.start_with?('event: ')
          streaming_state[:current_event] = line.sub('event: ', '')
          return
        end
        
        return unless line.start_with?('data: ')
        
        json_str = line.sub('data: ', '')
        
        begin
          json_data = JSON.parse(json_str)
          Rails.logger.debug("Anthropic chunk: #{json_data['type']}")
          
          process_anthropic_event(json_data, streaming_state, &block)
          
        rescue JSON::ParserError => e
          Rails.logger.error("Failed to parse Anthropic streaming chunk: #{e.message}, chunk: #{json_str[0..200]}...")
        end
      end
      
      def process_anthropic_event(json_data, streaming_state, &block)
        event_type = json_data['type']
        
        case event_type
        when 'message_start'
          # Extract message metadata
          message = json_data['message'] || {}
          streaming_state[:model_name] = message['model']
          streaming_state[:message_id] = message['id']
          
          # Extract usage from message_start
          if message['usage']
            streaming_state[:usage_info] ||= {}
            streaming_state[:usage_info]['prompt_tokens'] = message['usage']['input_tokens']
            
            # Check for cache tokens in message_start
            if message['usage']['cache_creation_input_tokens']
              streaming_state[:usage_info]['cache_creation_input_tokens'] = message['usage']['cache_creation_input_tokens']
            end
            if message['usage']['cache_read_input_tokens']
              streaming_state[:usage_info]['cache_read_input_tokens'] = message['usage']['cache_read_input_tokens']
            end
          end
          
        when 'content_block_start'
          content_block = json_data['content_block'] || {}
          
          if content_block['type'] == 'tool_use'
            # Start of a tool use block
            streaming_state[:current_tool_use] = {
              'type' => 'tool_use',
              'id' => content_block['id'],
              'name' => content_block['name'],
              'input' => {}
            }
            streaming_state[:tool_input_json] = ""
          end
          
        when 'content_block_delta'
          delta = json_data['delta'] || {}
          
          if delta['type'] == 'text_delta' && delta['text']
            # Text content
            streaming_state[:accumulated_content] += delta['text']
            yield({ chunk_type: 'content', content: delta['text'] }) if block_given?
            
          elsif delta['type'] == 'input_json_delta' && delta['partial_json']
            # Tool input JSON accumulation
            streaming_state[:tool_input_json] ||= ""
            streaming_state[:tool_input_json] += delta['partial_json']
          end
          
        when 'content_block_stop'
          # If we were building a tool use, finalize it
          if streaming_state[:current_tool_use]
            # Parse the accumulated JSON input
            if streaming_state[:tool_input_json].present?
              begin
                streaming_state[:current_tool_use]['input'] = JSON.parse(streaming_state[:tool_input_json])
              rescue JSON::ParserError => e
                Rails.logger.error("Failed to parse tool input JSON: #{e.message}")
                streaming_state[:current_tool_use]['input'] = {}
              end
            end
            
            streaming_state[:tool_calls] << streaming_state[:current_tool_use]
            yield({ chunk_type: 'tool_call_update', tool_calls: streaming_state[:tool_calls] }) if block_given?
            
            streaming_state[:current_tool_use] = nil
            streaming_state[:tool_input_json] = nil
          end
          
        when 'message_delta'
          delta = json_data['delta'] || {}
          
          if delta['stop_reason']
            streaming_state[:finish_reason] = delta['stop_reason']
          end
          
          # Extract completion tokens from message_delta
          if json_data['usage']
            streaming_state[:usage_info] ||= {}
            streaming_state[:usage_info]['completion_tokens'] = json_data['usage']['output_tokens']
            
            # Calculate total
            prompt = streaming_state[:usage_info]['prompt_tokens'].to_i
            completion = streaming_state[:usage_info]['completion_tokens'].to_i
            streaming_state[:usage_info]['total_tokens'] = prompt + completion
          end
          
        when 'message_stop'
          streaming_state[:content_complete] = true
          yield({ chunk_type: 'finish', finish_reason: streaming_state[:finish_reason] }) if block_given?
          
        when 'error'
          error_obj = json_data['error'] || {}
          error_message = error_obj['message'] || 'Unknown error'
          Rails.logger.error("[ANTHROPIC API ERROR] #{error_message}")
          
          streaming_state[:api_error] = error_message
          
          yield({
            chunk_type: 'error',
            error_message: translate_anthropic_error(error_message),
            raw_error: error_message
          }) if block_given?
          
        when 'ping'
          # Keep-alive ping, ignore
        end
      end
      
      def translate_anthropic_error(error_message)
        case error_message
        when /rate limit/i, /too many requests/i
          "Le service est temporairement surchargé. Veuillez réessayer dans quelques instants."
        when /invalid_api_key/i
          "Erreur d'authentification avec le service. Veuillez contacter l'administrateur."
        when /context.*too long/i, /maximum context length/i
          "La conversation est devenue trop longue. Veuillez démarrer une nouvelle conversation."
        when /content.*filter/i, /safety/i
          "Le contenu a été filtré pour des raisons de sécurité."
        when /overloaded/i
          "Le service est temporairement surchargé. Veuillez réessayer."
        else
          "Erreur API: #{error_message.truncate(200)}"
        end
      end
      
      def log_anthropic_final_usage(streaming_state)
        usage = streaming_state[:usage_info]
        return unless usage
        
        Rails.logger.info("ANTHROPIC STREAMING COMPLETE - Final usage: #{usage.inspect}")
        
        prompt_tokens = usage['prompt_tokens'].to_i
        completion_tokens = usage['completion_tokens'].to_i
        cache_creation = usage['cache_creation_input_tokens'].to_i
        cache_read = usage['cache_read_input_tokens'].to_i
        
        Rails.logger.info("[ANTHROPIC USAGE] prompt=#{prompt_tokens}, completion=#{completion_tokens}, total=#{prompt_tokens + completion_tokens}")
        
        if cache_creation > 0 || cache_read > 0
          hit_rate = prompt_tokens > 0 ? ((cache_read.to_f / prompt_tokens) * 100).round(1) : 0
          Rails.logger.info("[ANTHROPIC CACHE] creation=#{cache_creation}, read=#{cache_read}, hit_rate=#{hit_rate}%")
        end
      end
    end
  end
end
