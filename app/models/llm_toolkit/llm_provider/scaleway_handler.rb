# frozen_string_literal: true

module LlmToolkit
  class LlmProvider < ApplicationRecord
    module ScalewayHandler
      extend ActiveSupport::Concern

      SCALEWAY_API_URL = 'https://api.scaleway.ai/v1'

      private

      # Non-streaming call to Scaleway Generative API
      # Scaleway uses OpenAI-compatible format
      def call_scaleway(llm_model, system_messages, conversation_history, tools = nil)
        client = Faraday.new(url: SCALEWAY_API_URL) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
          f.options.timeout = 300
          f.options.open_timeout = 10
        end

        # Format messages for Scaleway (OpenAI-compatible format)
        formatted_system_messages = format_system_messages_for_scaleway(system_messages)
        formatted_conversation = format_conversation_for_scaleway(conversation_history)
        messages = formatted_system_messages + formatted_conversation

        model_name = llm_model.model_id.presence || llm_model.name
        # Scaleway has model-specific limits (e.g., llama-3.3-70b max is 4096)
        configured_max = settings&.dig('max_tokens')&.to_i.presence || LlmToolkit.config.default_max_tokens
        max_tokens = [configured_max, 4096].min # Cap at 4096 for safety

        Rails.logger.info("Scaleway - Using model: #{model_name}")
        Rails.logger.info("Scaleway - Max tokens: #{max_tokens}")
        Rails.logger.info("Scaleway - Messages count: #{messages.size}")

        request_body = {
          model: model_name,
          messages: messages,
          max_tokens: max_tokens
        }

        # Add tools if provided (OpenAI format)
        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_scaleway(tools)
          request_body[:tool_choice] = "auto"
          Rails.logger.info("Scaleway - Tools count: #{request_body[:tools].size}")
        end

        if Rails.env.development?
          Rails.logger.debug "SCALEWAY REQUEST BODY: #{JSON.pretty_generate(request_body)}"
        end

        response = client.post('chat/completions') do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Authorization'] = "Bearer #{api_key}"
          req.body = request_body
        end

        if response.success?
          Rails.logger.info("Scaleway - Received successful response")
          standardize_scaleway_response(response.body)
        else
          Rails.logger.error("Scaleway API error: #{response.body}")
          body = response.body
          error_message = if body.is_a?(Hash)
                            body.dig('error', 'message') || body.to_s
                          else
                            body.to_s
                          end
          raise ApiError, "Scaleway API error: #{error_message}"
        end
      rescue Faraday::Error => e
        Rails.logger.error("Scaleway API network error: #{e.message}")
        raise ApiError, "Network error: #{e.message}"
      end

      # Streaming call to Scaleway API
      def stream_scaleway(llm_model, system_messages, conversation_history, tools = nil, &block)
        formatted_system_messages = format_system_messages_for_scaleway(system_messages)
        formatted_conversation = format_conversation_for_scaleway(conversation_history)
        messages = formatted_system_messages + formatted_conversation

        model_name = llm_model.model_id.presence || llm_model.name
        configured_max = settings&.dig('max_tokens')&.to_i.presence || LlmToolkit.config.default_max_tokens
        max_tokens = [configured_max, 4096].min # Cap at 4096 for safety

        Rails.logger.info("Scaleway Streaming - Using model: #{model_name}")
        Rails.logger.info("Scaleway Streaming - Max tokens: #{max_tokens}")

        request_body = {
          model: model_name,
          messages: messages,
          max_tokens: max_tokens,
          stream: true
        }

        tools = Array(tools)
        if tools.present?
          request_body[:tools] = format_tools_for_scaleway(tools)
          request_body[:tool_choice] = "auto"
        end

        # Initialize streaming state
        streaming_state = {
          accumulated_content: +"",  # Unfrozen string
          tool_calls: [],
          usage_info: nil,
          finish_reason: nil,
          content_complete: false,
          json_buffer: +""  # Unfrozen string
        }

        uri = URI("#{SCALEWAY_API_URL}/chat/completions")

        Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 300) do |http|
          request = Net::HTTP::Post.new(uri.path)
          request['Content-Type'] = 'application/json'
          request['Authorization'] = "Bearer #{api_key}"
          request['Accept'] = 'text/event-stream'
          request.body = request_body.to_json

          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              error_body = response.body
              Rails.logger.error("Scaleway streaming error: #{error_body}")
              raise ApiError, "Streaming error: #{error_body}"
            end

            response.read_body do |chunk|
              process_scaleway_streaming_chunk(chunk, streaming_state, &block)
            end
          end
        end

        # Process any remaining content in the buffer
        if streaming_state[:json_buffer].present?
          streaming_state[:json_buffer].split("\n").each do |line|
            process_scaleway_sse_line(line.strip, streaming_state, &block)
          end
        end

        # Build and return final response
        build_scaleway_streaming_response(streaming_state, model_name)
      end

      # Format system messages for Scaleway (OpenAI format)
      def format_system_messages_for_scaleway(system_messages)
        return [] if system_messages.blank?

        # Combine all system messages into one
        combined_text = system_messages.map { |msg| msg[:text] || msg['text'] }.compact.join("\n\n")

        return [] if combined_text.blank?

        [{ role: "system", content: combined_text }]
      end

      # Format conversation history for Scaleway (OpenAI format)
      def format_conversation_for_scaleway(conversation_history)
        return [] if conversation_history.blank?

        conversation_history.map do |msg|
          formatted = {
            role: msg[:role] || msg['role'],
            content: extract_text_content_for_scaleway(msg[:content] || msg['content'])
          }

          # Handle tool calls in assistant messages
          if formatted[:role] == 'assistant' && (msg[:tool_calls] || msg['tool_calls'])
            formatted[:tool_calls] = msg[:tool_calls] || msg['tool_calls']
          end

          # Handle tool results
          if formatted[:role] == 'tool'
            formatted[:tool_call_id] = msg[:tool_call_id] || msg['tool_call_id']
          end

          formatted
        end
      end

      # Extract text content from various formats
      def extract_text_content_for_scaleway(content)
        return content if content.is_a?(String)
        return "" if content.nil?

        if content.is_a?(Array)
          # Extract text from content blocks
          text_parts = content.map do |part|
            if part.is_a?(Hash)
              part[:text] || part['text'] || part[:content] || part['content']
            else
              part.to_s
            end
          end
          text_parts.compact.join("\n")
        else
          content.to_s
        end
      end

      # Standardize Scaleway response to our internal format
      def standardize_scaleway_response(response)
        choice = response.dig('choices', 0) || {}
        message = choice['message'] || {}

        # Process tool calls if present
        tool_calls = []
        if message['tool_calls'].present?
          tool_calls = message['tool_calls'].map do |tc|
            {
              'name' => tc.dig('function', 'name'),
              'input' => parse_scaleway_tool_arguments(tc.dig('function', 'arguments')),
              'id' => tc['id']
            }
          end
        end

        {
          'content' => message['content'] || '',
          'model' => response['model'],
          'role' => message['role'],
          'stop_reason' => choice['finish_reason'],
          'stop_sequence' => nil,
          'tool_calls' => tool_calls,
          'usage' => response['usage'],
          'finish_reason' => choice['finish_reason']
        }
      end

      # Format tools for Scaleway (OpenAI format)
      def format_tools_for_scaleway(tools)
        return [] if tools.blank?

        tools.map do |tool|
          {
            type: "function",
            function: {
              name: tool[:name] || tool['name'],
              description: tool[:description] || tool['description'],
              parameters: tool[:input_schema] || tool['input_schema'] || tool[:parameters] || tool['parameters']
            }
          }
        end
      end

      # Process streaming chunks from Scaleway
      def process_scaleway_streaming_chunk(chunk, streaming_state, &block)
        chunk.force_encoding('UTF-8')
        return if chunk.strip.empty?

        streaming_state[:json_buffer] << chunk

        # Process complete lines
        while streaming_state[:json_buffer].include?("\n")
          line, streaming_state[:json_buffer] = streaming_state[:json_buffer].split("\n", 2)
          process_scaleway_sse_line(line.strip, streaming_state, &block)
        end
      end

      # Process a single SSE line from Scaleway
      def process_scaleway_sse_line(line, streaming_state, &block)
        return if line.empty? || line.start_with?(':')

        if line == 'data: [DONE]'
          streaming_state[:content_complete] = true
          return
        end

        return unless line.start_with?('data: ')

        json_str = line.sub(/^data: /, '')

        begin
          json_data = JSON.parse(json_str)

          # Capture usage info if present
          if json_data['usage'].present?
            streaming_state[:usage_info] = json_data['usage']
          end

          first_choice = json_data['choices']&.first
          return unless first_choice

          # Handle content delta
          if first_choice['delta'] && first_choice['delta']['content']
            new_content = first_choice['delta']['content']
            streaming_state[:accumulated_content] += new_content
            yield({ chunk_type: 'content', content: new_content }) if block_given?
          end

          # Handle tool calls delta
          if first_choice['delta'] && first_choice['delta']['tool_calls']
            process_scaleway_tool_calls(first_choice['delta']['tool_calls'], streaming_state[:tool_calls], &block)
          end

          # Handle finish reason
          if first_choice['finish_reason']
            streaming_state[:content_complete] = true
            streaming_state[:finish_reason] = first_choice['finish_reason']
            yield({ chunk_type: 'finish', finish_reason: streaming_state[:finish_reason] }) if block_given?
          end

        rescue JSON::ParserError => e
          Rails.logger.error("Failed to parse Scaleway streaming chunk: #{e.message}")
        end
      end

      # Process tool calls from streaming response
      def process_scaleway_tool_calls(new_tool_calls, tool_calls, &block)
        new_tool_calls.each do |tool_call|
          index = tool_call['index']
          existing = tool_calls.find { |tc| tc['index'] == index }

          if existing
            # Update existing tool call
            existing['id'] = tool_call['id'] if tool_call['id']
            if tool_call['function']
              existing['function'] ||= {}
              existing['function']['name'] = tool_call['function']['name'] if tool_call['function']['name']
              existing['function']['arguments'] ||= ''
              existing['function']['arguments'] += tool_call['function']['arguments'] if tool_call['function']['arguments']
            end
          else
            # Create new tool call entry
            new_entry = {
              'index' => index,
              'id' => tool_call['id'],
              'type' => 'function',
              'function' => {
                'name' => tool_call.dig('function', 'name'),
                'arguments' => tool_call.dig('function', 'arguments') || ''
              }
            }
            tool_calls << new_entry
          end
        end

        yield({ chunk_type: 'tool_call_update', tool_calls: tool_calls }) if block_given?
      end

      # Build final response from streaming state
      def build_scaleway_streaming_response(streaming_state, model_name)
        # Format tool calls to match expected output format
        formatted_tool_calls = streaming_state[:tool_calls].map do |tc|
          {
            'name' => tc.dig('function', 'name'),
            'input' => parse_scaleway_tool_arguments(tc.dig('function', 'arguments')),
            'id' => tc['id']
          }
        end

        {
          'content' => streaming_state[:accumulated_content],
          'model' => model_name,
          'role' => 'assistant',
          'stop_reason' => streaming_state[:finish_reason],
          'stop_sequence' => nil,
          'tool_calls' => formatted_tool_calls,
          'usage' => streaming_state[:usage_info],
          'finish_reason' => streaming_state[:finish_reason]
        }
      end

      # Parse tool arguments from JSON string
      def parse_scaleway_tool_arguments(arguments)
        return {} if arguments.blank?
        JSON.parse(arguments)
      rescue JSON::ParserError
        { 'raw' => arguments }
      end
    end
  end
end
