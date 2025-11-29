module LlmToolkit
  class LlmProvider < ApplicationRecord
    include SystemMessageFormatter
    include OpenrouterHandler
    
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
      validate_tools_format(tools)
      
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
      validate_tools_format(tools)
      
      # Stream response from OpenRouter
      stream_openrouter(target_llm_model, system_messages, conversation_history, tools, &block)
    end

    # Finds the default LlmModel for this provider
    # Returns the model with the lowest position
    # @return [LlmModel, nil] The default model or nil if none is set
    def default_llm_model
      llm_models.ordered.first
    end

    private

    def validate_tools_format(tools)
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
    end

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

      # Use the model_id for API calls, not the display name
      model_name = llm_model.model_id.presence || llm_model.name
      max_tokens = settings&.dig('max_tokens').to_i || LlmToolkit.config.default_max_tokens
      Rails.logger.info("Using model: #{model_name}")
      Rails.logger.info("Max tokens : #{max_tokens}")

      # Format system messages for Anthropic (simple text format)
      system_content = format_system_messages_for_anthropic(system_messages)

      request_body = {
        model: model_name,
        system: system_content,
        messages: conversation_history,
        tools: all_tools,
        max_tokens: max_tokens
      }
      request_body[:tool_choice] = {type: "auto"} if tools.present?
    
      Rails.logger.info("System Messages: #{system_content}")
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
        tc['function']['arguments'] = fix_malformed_json(args_str)
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
        input = parse_tool_arguments(function['arguments'])
        
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

    def fix_malformed_json(args_str)
      # Case 1: Arguments string is missing opening brace
      if !args_str.start_with?('{') && !args_str.end_with?('}')
        return "{#{args_str}}"
      elsif !args_str.start_with?('{')
        return "{#{args_str}"
      elsif !args_str.end_with?('}')
        return "#{args_str}}"
      end
      
      # Case 2: Try to detect and complete partial "query" format
      # Common pattern: "y": "something"
      if args_str.match(/^y["']?\s*:\s*["']/)
        return "{\"quer#{args_str}}"
      end
      
      # Case 3: Handle unclosed strings
      # This is hard to fix perfectly, but we can try a simple approach
      if args_str.count('"') % 2 == 1
        return "#{args_str}\""
      end
      
      args_str
    end

    def parse_tool_arguments(arguments_str)
      return {} if arguments_str.blank?
      
      begin
        if arguments_str.is_a?(String)
          # If the arguments string looks like JSON, parse it
          if arguments_str.start_with?('{') && arguments_str.end_with?('}')
            JSON.parse(arguments_str)
          else
            # If it doesn't look like JSON but has key-value pattern, try to reconstruct
            parse_key_value_arguments(arguments_str)
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
    end

    def parse_key_value_arguments(arg_str)
      arg_str = arg_str.strip
      return {'raw_input' => arg_str} unless arg_str.include?(':')
      
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
