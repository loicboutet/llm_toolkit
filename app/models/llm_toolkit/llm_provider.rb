module LlmToolkit
  class LlmProvider < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :llm_models, dependent: :destroy, class_name: 'LlmToolkit::LlmModel', foreign_key: 'llm_provider_id'

    validates :name, presence: true, uniqueness: { scope: [:owner_id, :owner_type] }
    validates :api_key, presence: true
    validates :provider_type, presence: true, inclusion: { in: %w[anthropic openrouter] }

    class ApiError < StandardError; end

    # @param system_messages [Array<Hash>] System messages for the LLM
    # @param conversation_history [Array<Hash>] Previous messages in the conversation
    # @param tools [Array<Hash>, nil] Tools available for the LLM
    # @param llm_model [LlmModel, nil] The specific model to use. Defaults to the provider's default model.
    # @return [Hash] Standardized response from the LLM API
    def call(system_messages, conversation_history, tools = nil, llm_model: nil)
      target_llm_model = llm_model || default_llm_model
      raise ApiError, "No suitable LLM model found for provider #{name}" unless target_llm_model

      # Ensure we have valid arrays
      system_messages = Array(system_messages)
      conversation_history = Array(conversation_history)
      tools = Array(tools)
      
      # Validate tools format
      tools.each do |tool|
        unless tool.is_a?(Hash) && tool[:name].present? && tool[:description].present?
          Rails.logger.warn "Invalid tool format detected: #{tool.inspect}"
          
          # Provide a default description if missing
          if tool[:name].present? && tool[:description].nil?
            tool[:description] = "Tool for #{tool[:name]}"
            Rails.logger.info "Added default description for tool: #{tool[:name]}"
          end
        end
      end
      case provider_type
      when 'anthropic'
        call_anthropic(target_llm_model, system_messages, conversation_history, tools)
      when 'openrouter'
        call_openrouter(target_llm_model, system_messages, conversation_history, tools)
      else
        raise ApiError, "Unsupported provider type: #{provider_type}"
      end
    end
    
    # Stream chat implementation for OpenRouter
    # Accepts a block that will be called with each chunk of the streamed response
    # @param system_messages [Array<Hash>] System messages for the LLM
    # @param conversation_history [Array<Hash>] Previous messages in the conversation
    # @param tools [Array<Hash>, nil] Tools available for the LLM
    # @param llm_model [LlmModel, nil] The specific model to use. Defaults to the provider's default model.
    # @yield [Hash] Yields each chunk of the streamed response
    # @return [Hash] Standardized final response from the LLM API stream
    def stream_chat(system_messages, conversation_history, tools = nil, llm_model: nil, &block)
      target_llm_model = llm_model || default_llm_model
      raise ApiError, "No suitable LLM model found for provider #{name}" unless target_llm_model

      # Validate provider type - currently only supporting OpenRouter
      unless provider_type == 'openrouter'
        raise ApiError, "Streaming is only supported for OpenRouter provider type"
      end

      # Ensure we have valid arrays
      system_messages = Array(system_messages)
      conversation_history = Array(conversation_history)
      tools = Array(tools)
      
      # Validate tools format
      tools.each do |tool|
        unless tool.is_a?(Hash) && tool[:name].present? && tool[:description].present?
          Rails.logger.warn "Invalid tool format detected: #{tool.inspect}"
          
          # Provide a default description if missing
          if tool[:name].present? && tool[:description].nil?
            tool[:description] = "Tool for #{tool[:name]}"
            Rails.logger.info "Added default description for tool: #{tool[:name]}"
          end
        end
      end
      # Stream response from OpenRouter
      stream_openrouter(target_llm_model, system_messages, conversation_history, tools, &block)
    end

    # Finds the default LlmModel for this provider
    # @return [LlmModel, nil] The default model or nil if none is set
    def default_llm_model
      llm_models.default.first || llm_models.first
    end

    private

    def call_anthropic(llm_model, system_messages, conversation_history, tools = nil)
      client = Faraday.new(url: 'https://api.anthropic.com') do |f|
        f.request :json
        f.response :json
        f.adapter Faraday.default_adapter
        f.options.timeout = 300 # Set timeout to 5 minutes
        f.options.open_timeout = 10 # Set open timeout to 10 seconds
      end

      tools = Array(tools)
      all_tools = tools.presence || LlmToolkit::ToolService.tool_definitions
      
      Rails.logger.info("Tools count: #{all_tools.size}")
      all_tools.each_with_index do |tool, idx|
        Rails.logger.info("Tool #{idx+1}: #{tool[:name]} - Desc: #{tool[:description] || 'MISSING!'}")
      end

      # Use the specific model name passed in
      model_name = llm_model.name
      max_tokens = settings&.dig('max_tokens').to_i || LlmToolkit.config.default_max_tokens
      Rails.logger.info("Using model: #{model_name}")
      Rails.logger.info("Max tokens : #{max_tokens}")

      request_body = {
        model: model_name,
        system: system_messages,
        messages: conversation_history,
        tools: all_tools,
        max_tokens: max_tokens
      }
      request_body[:tool_choice] = {type: "auto"} if tools.present?
    
      Rails.logger.info("System Messages: #{system_messages}")
      Rails.logger.info("Conversation History: #{conversation_history}")
      
      # Detailed request logging
      if Rails.env.development?
        Rails.logger.debug "ANTHROPIC REQUEST BODY: #{JSON.pretty_generate(request_body)}"
      end

      response = client.post('/v1/messages') do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['x-api-key'] = api_key
        req.headers['anthropic-version'] = '2023-06-01'
        req.headers['anthropic-beta'] = 'prompt-caching-2024-07-31'
        req.body = request_body.to_json
      end

      if response.success?
        Rails.logger.info("LlmProvider - Received successful response from Anthropic API:")
        Rails.logger.info(response.body)
        standardize_response(response.body)
      else
        Rails.logger.error("Anthropic API error: #{response.body}")
        raise ApiError, "API error: #{response.body['error']['message']}"
      end
    rescue Faraday::Error => e
      Rails.logger.error("Anthropic API error: #{e.message}")
      raise ApiError, "Network error: #{e.message}"
    end

    def call_openrouter(llm_model, system_messages, conversation_history, tools = nil)
      client = Faraday.new(url: 'https://openrouter.ai/api/v1') do |f|
        f.request :json
        f.response :json
        f.adapter Faraday.default_adapter
        f.options.timeout = 300
        f.options.open_timeout = 10
      end

      # Ensure system_messages is properly formatted and not nil
      system_message_content = if system_messages.present?
                                 system_messages.map { |msg| msg.is_a?(Hash) ? msg[:text] : msg.to_s }.join("\n")
                               else
                                 "You are an AI assistant."
                               end

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

      messages = [
        { role: 'system', content: system_message_content }
      ] + fixed_conversation_history

      # Use the specific model name passed in
      model_name = llm_model.name
      max_tokens = settings&.dig('max_tokens') || LlmToolkit.config.default_max_tokens
      Rails.logger.info("Using model: #{model_name}")
      Rails.logger.info("Max tokens : #{max_tokens}")

      request_body = {
        model: model_name,
        messages: messages,
        stream: false,
        usage: {
          "include": true
        },
        max_tokens: max_tokens
      }

      tools = Array(tools)
      if tools.present?
        request_body[:tools] = format_tools_for_openrouter(tools)
       # request_body[:tool_choice] = { type: 'auto' }
      end

      Rails.logger.info("OpenRouter Request - Messages: #{messages}")
      Rails.logger.info("OpenRouter Request - Tools: #{request_body[:tools] || []}")
      
      # Detailed request logging
      if Rails.env.development?
        Rails.logger.debug "OPENROUTER REQUEST BODY: #{JSON.pretty_generate(request_body)}"
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

      # Ensure system_messages is properly formatted and not nil
      system_message_content = if system_messages.present?
                                 system_messages.map { |msg| msg.is_a?(Hash) ? msg[:text] : msg.to_s }.join("\n")
                               else
                                 "You are an AI assistant."
                               end

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

      messages = [
        { role: 'system', content: system_message_content }
      ] + fixed_conversation_history

      # Use the specific model name passed in
      model_name = llm_model.name
 #     max_tokens = settings&.dig('max_tokens') || LlmToolkit.config.default_max_tokens
      Rails.logger.info("Using model: #{model_name}")
 #     Rails.logger.info("Max tokens : #{max_tokens}")

      request_body = {
        model: model_name,
        messages: messages,
        stream: true, # Enable streaming
        usage: {
          "include": true
        }
  #      max_tokens: max_tokens
      }

      tools = Array(tools)
      if tools.present?
        request_body[:tools] = format_tools_for_openrouter(tools)
        # request_body[:tool_choice] = { type: 'auto' }
      end

      Rails.logger.info("OpenRouter Streaming Request - Messages count: #{messages.size}")
      Rails.logger.info("OpenRouter Streaming Request - Tools count: #{request_body[:tools]&.size || 0}")
      
      # Detailed request logging
      if Rails.env.development?
        Rails.logger.debug "OPENROUTER STREAMING REQUEST BODY: #{JSON.pretty_generate(request_body)}"
      end

      # Initialize variables to track the streaming response
      accumulated_content = ""
      tool_calls = []
      model_name = nil
      usage_info = nil
      content_complete = false
      finish_reason = nil

      response = client.post('chat/completions') do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Authorization'] = "Bearer #{api_key}"
        #req.headers['HTTP-Referer'] = LlmToolkit.config.referer_url
        req.headers['X-Title'] = 'Development Environment'
        req.body = request_body.to_json
        req.options.on_data = proc do |chunk, size, env|
          # Force chunk encoding to UTF-8 to prevent Encoding::CompatibilityError
          chunk.force_encoding('UTF-8')
          next if chunk.strip.empty?
          
          # Remove 'data: ' prefix from each line and skip comment lines
          chunk.each_line do |line|
            # Ensure line is also UTF-8, though force_encoding on chunk should handle this
            trimmed_line = line.strip 
            next if trimmed_line.empty? || trimmed_line.start_with?(':')
            
            # Check for [DONE] marker
            if trimmed_line == 'data: [DONE]'
              content_complete = true
              next
            end
            
            # Extract the JSON part from the SSE line
            json_str = trimmed_line.sub(/^data: /, '')
            
            begin
              # Parse the chunk JSON
              json_data = JSON.parse(json_str)
              Rails.logger.info("OpenRouter chunk : #{json_data}")

              # Record model name if not yet set
              model_name ||= json_data['model']
              
              # Check if this is a tool call chunk
              first_choice = json_data['choices']&.first
              if first_choice
                # Record usage if present (typically in the final chunk)
                usage_info = json_data['usage'] if json_data['usage']
                
                # Check for delta for text content
                if first_choice['delta'] && first_choice['delta']['content']
                  new_content = first_choice['delta']['content']
                  accumulated_content += new_content
                  
                  # Pass the new content to the block
                  yield({ chunk_type: 'content', content: new_content }) if block_given?
                end
                
                # Check for a tool call in the delta
                if first_choice['delta'] && first_choice['delta']['tool_calls']
                  new_tool_calls = first_choice['delta']['tool_calls']
                  
                  # Process the tool call
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
                    else
                      # Create a new tool call entry
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
                      
                      # Add to the list of tool calls
                      tool_calls << new_entry
                    end
                  end
                  
                  # Signal that we have a tool call update
                  yield({ chunk_type: 'tool_call_update', tool_calls: tool_calls }) if block_given?
                end
                
                # Check for finish_reason (signals end of content or tool call)
                if first_choice['finish_reason']
                  content_complete = true
                  finish_reason = first_choice['finish_reason']
                  
                  # If we have a non-nil finish reason, the response is complete
                  yield({ chunk_type: 'finish', finish_reason: finish_reason }) if block_given?
                end
              end
            rescue JSON::ParserError => e
              Rails.logger.error("Failed to parse streaming chunk: #{e.message}, chunk: #{trimmed_line}")
            end
          end
        end
      end
      
      # Verify response code
      unless (200..299).cover?(response.status)
        Rails.logger.error("OpenRouter API streaming error: Status #{response.status}")
        raise ApiError, "API streaming error: Status #{response.status}"
      end
      
      # Format the final result
      formatted_tool_calls = format_tools_response_from_openrouter(tool_calls) if tool_calls.any?
      
      # Return the complete response object
      {
        'content' => accumulated_content,
        'model' => model_name,
        'role' => 'assistant',
        'stop_reason' => content_complete ? 'stop' : nil,
        'stop_sequence' => nil,
        'tool_calls' => formatted_tool_calls || [],
        'usage' => usage_info,
        'finish_reason' => finish_reason
      }
    rescue Faraday::Error => e
      Rails.logger.error("OpenRouter API streaming error: #{e.message}")
      raise ApiError, "Network error during streaming: #{e.message}"
    end

    # Standardize the Anthropic API response to our internal format
    def standardize_response(response)
      content = response.dig('content', 0, 'text')
      tool_calls = response['content'].select { |c| c['type'] == 'tool_use' } if response['content'].is_a?(Array)
      
      {
        'content' => content || "",
        'model' => response['model'],
        'role' => response['role'],
        'stop_reason' => response['stop_reason'],
        'stop_sequence' => response['stop_sequence'],
        'tool_calls' => tool_calls || [],
        'usage' => response['usage'],
        'finish_reason' => response['stop_reason']
      }
    end

    # Convert OpenRouter response to match our standardized format
    def standardize_openrouter_response(response)
      # Get the first choice
      choice = response.dig('choices', 0) || {}
      message = choice['message'] || {}
      
      # Log for debugging
      Rails.logger.debug("OpenRouter response message: #{message.inspect}")
      
      # Check if this is a tool call message
      has_tool_calls = message['tool_calls'].present?
      tool_calls = []
      
      # Process tool calls if present
      if has_tool_calls
        Rails.logger.info("Tool calls detected in OpenRouter response")
        tool_calls = format_tools_response_from_openrouter(message['tool_calls'])
      end
      
      # Get the content text - this will be nil/empty for tool call messages
      content = message['content']
      
      # Format the response
      result = {
        # For tool call messages, content may be null, in which case we provide an empty string
        'content' => content || "",
        'model' => response['model'],
        'role' => message['role'],
        'stop_reason' => choice['finish_reason'],
        'stop_sequence' => nil,
        'tool_calls' => tool_calls,
        'usage' => response['usage'],
        'finish_reason' => choice['finish_reason']
      }
      
      # Log the standardized response for debugging
      Rails.logger.debug("Standardized OpenRouter response: #{result.inspect}")
      
      result
    end

    def format_tools_response_from_openrouter(tool_calls)
      return [] if tool_calls.nil? || tool_calls.empty?
      
      Rails.logger.debug("Formatting OpenRouter tool calls: #{tool_calls.inspect}")
      
      # PHASE 1: Merge accumulated tool call fragments by index
      # Initialize hash to store merged tool calls indexed by their position in the sequence
      merged_by_index = {}
      
      # First pass: group tool calls by index and merge them
      tool_calls.each do |tc|
        index = tc['index']
        next unless index.is_a?(Integer) # Skip tool calls without a valid index
        
        # Initialize entry for this index if it doesn't exist
        merged_by_index[index] ||= {
          'id' => nil,
          'index' => index,
          'type' => 'function',
          'function' => {'name' => nil, 'arguments' => ''}
        }
        
        # Copy ID if available
        merged_by_index[index]['id'] = tc['id'] if tc['id']
        
        # Copy type if available
        merged_by_index[index]['type'] = tc['type'] if tc['type']
        
        # Update function data
        if tc['function']
          # Copy function name if available
          if tc['function']['name']
            merged_by_index[index]['function']['name'] = tc['function']['name']
          end
          
          # Concatenate arguments if available
          if tc['function']['arguments']
            merged_by_index[index]['function']['arguments'] += tc['function']['arguments']
          end
        end
      end
      
      # Convert back to array
      merged_tool_calls = merged_by_index.values
      
      # PHASE 2: Handle special cases and fix broken arguments
      # Look for partial arguments strings that need to be merged
      merged_tool_calls.each do |tc|
        # Skip if we don't have arguments
        next unless tc['function'] && tc['function']['arguments']
        
        # Fix common issues with the arguments string
        args_str = tc['function']['arguments'].strip
        
        # If arguments string is empty, initialize it to empty object
        if args_str.empty?
          tc['function']['arguments'] = '{}'
          next
        end
        
        # Try to fix malformed JSON
        
        # Case 1: Arguments string is missing opening brace
        if !args_str.start_with?('{') && !args_str.end_with?('}')
          tc['function']['arguments'] = "{#{args_str}}"
        elsif !args_str.start_with?('{')
          tc['function']['arguments'] = "{#{args_str}"
        elsif !args_str.end_with?('}')
          tc['function']['arguments'] = "#{args_str}}"
        end
        
        # Case 2: Try to detect and complete partial "query" format
        # Common pattern: "y": "something"
        if args_str.match(/^y["']?\s*:\s*["']/)
          tc['function']['arguments'] = "{\"quer#{args_str}}"
        end
        
        # Case 3: Handle unclosed strings
        # This is hard to fix perfectly, but we can try a simple approach
        if args_str.count('"') % 2 == 1
          tc['function']['arguments'] = "#{args_str}\""
        end
      end
      
      # PHASE 3: Parse arguments into proper input hash
      # Format each tool call to the expected structure
      formatted_tool_calls = merged_tool_calls.map do |tc|
        function = tc['function'] || {}
        
        # Check if this tool has all required parts
        has_id = tc['id'].present?
        has_name = function['name'].present?
        
        # Skip empty or invalid tool calls
        next nil if !has_name && function['arguments'].blank?
        
        # Try to parse the arguments string into a hash
        input = begin
          if function['arguments'].is_a?(String)
            # If the arguments string looks like JSON, parse it
            if function['arguments'].start_with?('{') && function['arguments'].end_with?('}')
              JSON.parse(function['arguments'])
            else
              # If it doesn't look like JSON but has key-value pattern, try to reconstruct
              arg_str = function['arguments'].strip
              if arg_str.include?(':')
                # Extract key and value based on a simple key:value pattern
                key, value = arg_str.split(':', 2).map(&:strip)
                
                # Remove quotes from key if present
                key = key.gsub(/["']/, '')
                
                # If value looks like a string (has quotes), strip them
                if value.start_with?('"') && value.end_with?('"')
                  value = value[1..-2]
                elsif value.start_with?("'") && value.end_with?("'")
                  value = value[1..-2]
                # If it looks like a number, convert it
                elsif value =~ /^\d+$/
                  value = value.to_i
                elsif value =~ /^\d+\.\d+$/
                  value = value.to_f
                end
                
                {key => value}
              else
                # Can't parse it, return it as a raw string
                {'raw_input' => arg_str}
              end
            end
          else
            # Not a string, return empty hash
            {}
          end
        rescue JSON::ParserError => e
          Rails.logger.error("Error parsing tool arguments: #{e.message}")
          {}
        rescue => e
          Rails.logger.error("Unknown error parsing arguments: #{e.message}")
          {}
        end
        
        # Handle special case: vector_search vs text_search
        # If name is missing but we have query parameter, use appropriate search tool
        if !has_name && input["query"].present?
          # Choose which search to use based on context or default to vector_search
          function['name'] = "vector_search"
        end
        
        # Return the standardized format expected by our system
        {
          "name" => function['name'],
          "input" => input,
          "id" => tc['id']
        }
      end.compact # Remove nils
      
      # Log the result
      Rails.logger.debug("Formatted tool calls: #{formatted_tool_calls.inspect}")
      
      formatted_tool_calls
    end

    def format_tools_for_openrouter(tools)
      return [] if tools.nil?
      
      formatted_tools = tools.map do |tool|
        {
          type: "function",
          function: {
            name: tool[:name],
            description: tool[:description] || "Tool for #{tool[:name]}",
            parameters: tool[:input_schema]
          }
        }
      end
      
      Rails.logger.debug("Formatted tools for OpenRouter: #{formatted_tools.inspect}")
      formatted_tools
    end
  end
end