# Ensure Turbo::StreamsChannel is available
require 'turbo-rails' 

module LlmToolkit
  class CallStreamingLlmWithToolService
    # Rendering helpers removed - broadcasting raw chunks
    
    # Placeholder markers to detect and clear initial "thinking" messages
    PLACEHOLDER_MARKERS = [
      "🤔 Traitement de votre demande...",
      "🎯 Analyse automatique en cours..."
    ].freeze

    attr_reader :llm_model, :llm_provider, :conversation, :assistant_message, :conversable, :role, :tools, :user_id, :tool_classes, :broadcast_to

    # Initialize the service with necessary parameters
    #
    # @param llm_model [LlmModel] The model to use for LLM calls
    # @param conversation [Conversation] The conversation context
    # @param assistant_message [Message] The pre-created empty assistant message record
    # @param tool_classes [Array<Class>] Optional tool classes to use
    # @param user_id [Integer] ID of the user making the request
    # @param broadcast_to [String, nil] Optional channel for broadcasting updates
    def initialize(llm_model:, conversation:, assistant_message:, tool_classes: [], user_id: nil, broadcast_to: nil)
      @llm_model = llm_model
      @llm_provider = @llm_model.llm_provider # Derive provider from model
      @conversation = conversation
      @assistant_message = assistant_message # Store the passed message
      @conversable = conversation.conversable
      # @role = role || conversation.agent_type.to_sym # Role removed
      @user_id = user_id
      @tool_classes = tool_classes

      # Use passed tool classes or get from ToolService
      @tools = if tool_classes.any?
        ToolService.build_tool_definitions(tool_classes)
      else
        ToolService.tool_definitions
      end
      
      # Initialize variables to track streamed content using the passed message
      @current_message = @assistant_message # Use the passed message
      
      # Check if the initial content is a placeholder that should be cleared
      initial_content = @current_message.content || ""
      @is_placeholder_content = PLACEHOLDER_MARKERS.any? { |marker| initial_content.include?(marker) }
      
      # If it's a placeholder, start with empty content (will be replaced on first chunk)
      # Otherwise, keep the existing content for appending
      @current_content = @is_placeholder_content ? "" : initial_content
      
      @content_complete = false
      @content_chunks_received = !@is_placeholder_content && initial_content.present?
      # @current_tool_calls = [] # Replaced by accumulated_tool_calls
      @accumulated_tool_calls = {} # Accumulate tool call chunks by index
      @processed_tool_call_ids = Set.new
      @special_url_input = nil
      @tool_results_pending = false
      @finish_reason = nil
      
      # Add followup count to prevent infinite loops
      @followup_count = 0
      @max_followups = 100 # Safety limit

      # Track the last error to avoid repeated error messages
      @last_error = nil
    end

    # Main method to call the LLM and process the streamed response
    # @return [Boolean] Success status
    def call
      # Return if LLM model or provider is missing
      return false unless @llm_model && @llm_provider

      # Validate provider supports streaming
      unless @llm_provider.provider_type == 'openrouter'
        Rails.logger.error("Streaming not supported for provider type: #{@llm_provider.provider_type}")
        return false
      end

      begin
        # Set conversation to working status
        @conversation.update(status: :working)

        # Start the LLM streaming interaction
        stream_llm

        true
      rescue => e
        Rails.logger.error("Error in CallStreamingLlmWithToolService: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        
        # Update message with error info if empty
        if @current_message && @current_message.content.blank?
          @current_message.update(
            content: "Sorry, an error occurred: #{e.message.truncate(200)}"
          )
        end
        
        false
      ensure
        # Set conversation status to resting when done, unless waiting for approval
        @conversation.update(status: :resting) unless @conversation.status_waiting?
      end
    end

    private

    # Stream responses from the LLM and process chunks
    def stream_llm
      # Get system prompt
      sys_prompt = if @conversable.respond_to?(:generate_system_messages)
                     @conversable.generate_system_messages(@role)
                   else
                      []
                    end

      # Get conversation history, formatted for the specific model's provider type
      # Role argument removed from history call
      conv_history = @conversation.history(llm_model: @llm_model)

      # NOTE: No need to create a message here, it's passed in via initialize
      
      # Call the LLM provider with streaming and handle each chunk
      # (Provider's stream_chat method will need refactoring later)
      # TODO: Refactor LlmProvider#stream_chat to accept llm_model details
      final_response = @llm_provider.stream_chat(sys_prompt, conv_history, @tools, llm_model:@llm_model) do |chunk|
        process_chunk(chunk)
      end

      # Update the current message with usage data if available
      if final_response && final_response['usage']
        usage = final_response['usage']
        # Update message with usage, using the renamed column
        @current_message.update(
          prompt_tokens: usage['prompt_tokens'].to_i,
          completion_tokens: usage['completion_tokens'].to_i,
          api_total_tokens: usage['total_tokens'].to_i # Use renamed column
        )
      end

      # Update the finish_reason from the final response if we don't have one from streaming
      if final_response && final_response['finish_reason'] && @finish_reason.nil?
        @finish_reason = final_response['finish_reason']
        @current_message.update(finish_reason: @finish_reason)
        Rails.logger.info("Updated finish_reason from final response: #{@finish_reason}")
      end

      # Final processing happens within the 'finish' chunk handler now.
      # Tool calls from the final_response might be redundant if streaming worked correctly,
      # but we keep this block as a fallback, although it might need review later
      # if it causes duplicate processing.
      if final_response && final_response['tool_calls'].present? && !@content_chunks_received && @accumulated_tool_calls.empty?
        Rails.logger.warn("Processing tool calls from final_response as no streaming chunks were processed.")
        # Format the tool calls from the final response
        formatted_tool_calls = @llm_provider.send(:format_tools_response_from_openrouter, final_response['tool_calls'])
        dangerous_encountered = process_tool_calls(formatted_tool_calls)

        # Make another call to the LLM with the tool results if we have some and no dangerous tools
        if !dangerous_encountered && @tool_results_pending
          # Add a small delay to ensure tool results are saved to the database
          sleep(0.5) 
          
          # Create a new message for the follow-up response
          Rails.logger.info("Making follow-up call to LLM with tool results from final response")
          followup_with_tools
        end
      end

      # Special case: If we collected a URL input but haven't created a get_url tool yet, create one now
      if @special_url_input && !@current_message.tool_uses.exists?(name: "get_url")
        dangerous_encountered = handle_special_url_tool
        
        # Make another call to the LLM with the tool results if no dangerous tools
        if !dangerous_encountered && @tool_results_pending
          # Add a small delay to ensure tool results are saved to the database
          sleep(0.5)
          
          # Create a new message for the follow-up response
          Rails.logger.info("Making follow-up call to LLM with tool results from special URL")
          followup_with_tools
        end
      end

      # Check if we have any tool results but haven't done a follow-up yet
      # This is CRITICAL - this is where the follow-up after tool execution happens
      Rails.logger.info("End of stream_llm - Tool results pending: #{@tool_results_pending}, Conversation waiting: #{@conversation.waiting?}")
      if @tool_results_pending && !@conversation.waiting?
        # Add a small delay to ensure tool results are saved to the database
        sleep(0.5)
        
        # Log that we're doing a follow-up after the end of streaming
        Rails.logger.info("Making follow-up call to LLM after end of streaming")
        followup_with_tools
      end
    end

    # Make a follow-up call to the LLM with the tool results
    def followup_with_tools
      # Skip if we're already waiting for approval
      return if @conversation.waiting?
      
      # Increment followup count and check safety limit
      @followup_count += 1
      if @followup_count > @max_followups
        Rails.logger.warn("Exceeded maximum number of followup calls (#{@max_followups}). Stopping.")
        return
      end

      Rails.logger.info("Starting follow-up call ##{@followup_count} to LLM with tool results")
      
      # Keep track of whether we had tool results before this call
      had_tool_results = @tool_results_pending
      
      # Reset streaming variables
      @current_content = ""
      # @current_tool_calls = [] # Replaced
      @accumulated_tool_calls = {} # Reset accumulator
      @processed_tool_call_ids = Set.new
      @content_complete = false
      @content_chunks_received = false
      @tool_results_pending = false
      @finish_reason = nil
      @is_placeholder_content = false # Follow-up messages don't have placeholders
      
      # Get updated conversation history with tool results
      sys_prompt = if @conversable.respond_to?(:generate_system_messages)
                     @conversable.generate_system_messages(@role)
                   else
                      []
                     end
      # Get updated conversation history with tool results, formatted for the model
      # Role argument removed from history call
      conv_history = @conversation.history(llm_model: @llm_model)

      # Log the conversation history for debugging
      Rails.logger.debug("Follow-up conversation history size: #{conv_history.size}")
      
      # Create a new message for the followup response, associated with the model
      @current_message = create_empty_message

      begin
        # Call the LLM provider with streaming and handle each chunk
        # (Provider's stream_chat method will need refactoring later)
        # TODO: Refactor LlmProvider#stream_chat to accept llm_model details
        final_response = @llm_provider.stream_chat(sys_prompt, conv_history, @tools) do |chunk|
          process_chunk(chunk)
        end

        # Update the current message (the follow-up message) with usage data if available
        if final_response && final_response['usage']
          usage = final_response['usage']
          # Update follow-up message with usage, using the renamed column
          @current_message.update(
            prompt_tokens: usage['prompt_tokens'].to_i,
            completion_tokens: usage['completion_tokens'].to_i,
            api_total_tokens: usage['total_tokens'].to_i # Use renamed column
          )
        end

        # Update the finish_reason from the final response if we don't have one from streaming
        if final_response && final_response['finish_reason'] && @finish_reason.nil?
          @finish_reason = final_response['finish_reason']
          @current_message.update(finish_reason: @finish_reason)
          Rails.logger.info("Updated finish_reason from final response: #{@finish_reason}")
        end

        # Handle any tool calls in the final response (if we didn't process them during streaming)
        if final_response && final_response['tool_calls'].present? && !@content_chunks_received
          formatted_tool_calls = @llm_provider.send(:format_tools_response_from_openrouter, final_response['tool_calls'])
          dangerous_encountered = process_tool_calls(formatted_tool_calls)
          
          # Recursively call followup_with_tools if we have more tool results
          if !dangerous_encountered && @tool_results_pending
            sleep(0.5)
            followup_with_tools
          end
        end
        
        # Important: If we had tool results before, but now @tool_results_pending is false
        # and still no dangerous tools encountered, check if the LLM is still trying to use tools
        # This is important for multi-step tool interactions
        if had_tool_results && !@tool_results_pending && !@conversation.waiting? &&
          @current_message.content.present? && looks_like_attempting_tool_use(@current_message.content)
          
          Rails.logger.info("LLM appears to be attempting to use tools again. Making another follow-up call.")
          @tool_results_pending = true
          sleep(0.5)
          followup_with_tools
        end
      rescue => e
        # Log the error
        error_message = "Error in followup call: #{e.message}"
        Rails.logger.error(error_message)
        Rails.logger.error(e.backtrace.join("\n"))
        
        # Update message with error only if it's empty
        if @current_message && @current_message.content.blank?
          @current_message.update(
            content: "Sorry, an error occurred during follow-up: #{e.message.truncate(200)}"
          )
        end
      end
    end
    
    # Check if the message content looks like it's attempting to use a tool
    def looks_like_attempting_tool_use(content)
      # Look for patterns that suggest the LLM is trying to use a tool
      patterns = [
        /I('ll)? (need to|should|will|want to) use/i,
        /Let('s| me)? use the/i,
        /I('ll)? search for/i,
        /I('ll)? need to (search|check|read|fetch)/i,
        /Using the .* tool/i,
        /Let('s| me)? (search|fetch|check|analyze)/i,
        /I'll (call|execute|invoke|use)/i,
        /I need to (call|execute|invoke|use)/i,
        /Je vais (utiliser|rechercher|lire|analyser)/i, # French patterns
        /Utilisons (le|la|les) tool/i,
        /Je dois (chercher|utiliser|lire)/i
      ]
      
      patterns.any? { |pattern| content.match?(pattern) }
    end

    # Process an individual chunk from the streaming response
    # @param chunk [Hash] The chunk data from the streamed response
    def process_chunk(chunk)
      begin
        case chunk[:chunk_type]
        when 'content'
          # Append content to the current message
          @current_content += chunk[:content]
          @content_chunks_received = true

          # Update the database record safely
          if @current_message
            @current_message.update(content: @current_content)
          else
            Rails.logger.error("Cannot update content: current_message is nil")
          end

        when 'error'
          # SIMPLE ERROR HANDLING - create error message
          Rails.logger.warn("OpenRouter API error encountered: #{chunk[:error_message]}")
          
          if @current_message
            @current_message.update(
              content: chunk[:error_message],
              is_error: true,
              finish_reason: 'error'
            )
          end
          
          @content_complete = true
          @finish_reason = 'error'

        when 'tool_call_update'
          # Accumulate tool call updates based on index
          if chunk[:tool_calls].is_a?(Array)
            chunk[:tool_calls].each do |partial_tool_call|
              index = partial_tool_call['index']
              next unless index.is_a?(Integer) # Ensure we have a valid index

              @accumulated_tool_calls[index] ||= {}
              # Use deep_merge! to combine nested structures like the 'function' hash
              begin
                @accumulated_tool_calls[index].deep_merge!(partial_tool_call)
              rescue => e
                Rails.logger.error("Error merging tool call: #{e.message}")
                Rails.logger.debug("Partial tool call: #{partial_tool_call.inspect}")
                Rails.logger.debug("Accumulated tool call: #{@accumulated_tool_calls[index].inspect}")
              end
            end
          else
            Rails.logger.error("Invalid tool_calls format: #{chunk[:tool_calls].inspect}")
          end

        when 'finish'
          @content_complete = true
          
          # Extract finish_reason from the chunk if available
          if chunk[:finish_reason].present?
            @finish_reason = chunk[:finish_reason]
            Rails.logger.info("Extracted finish_reason from chunk: #{@finish_reason}")
            
            # Update the message with the finish_reason
            @current_message.update(finish_reason: @finish_reason) if @current_message
          end

          # If we accumulated tool calls, process them
          unless @accumulated_tool_calls.empty?
            complete_tool_calls = @accumulated_tool_calls.values.sort_by { |tc| tc['index'] || 0 } # Sort by index just in case
            Rails.logger.debug "Accumulated complete tool calls: #{complete_tool_calls.inspect}"

            # Examine the *complete* tool calls for special handling
            examine_tool_calls_for_special_cases(complete_tool_calls)

            # Format the tool calls to our internal format
            formatted_tool_calls = @llm_provider.send(:format_tools_response_from_openrouter, complete_tool_calls)
            Rails.logger.debug "Formatted tool calls for processing: #{formatted_tool_calls.inspect}"

            dangerous_encountered = process_tool_calls(formatted_tool_calls)
            
            # Immediately check if we need a follow-up call for tools
            if @tool_results_pending && !@conversation.waiting? && !dangerous_encountered
              Rails.logger.info("Tool results pending after processing tools in 'finish' handler - initiating followup")
              followup_with_tools
            else
              Rails.logger.info("No immediate followup needed: pending=#{@tool_results_pending}, waiting=#{@conversation.waiting?}, dangerous=#{dangerous_encountered}")
            end
          end
          # Reset accumulator for potential follow-up calls
          @accumulated_tool_calls = {}
        else
          Rails.logger.warn("Unknown chunk type: #{chunk[:chunk_type]}")
        end
      rescue => e
        error_message = "Error processing chunk: #{e.message}"
        
        # Only log if this is a new error (avoid filling logs with repetitive errors)
        unless error_message == @last_error
          Rails.logger.error(error_message)
          Rails.logger.error(e.backtrace.join("\n"))
          Rails.logger.error("Chunk that caused error: #{chunk.inspect}")
          @last_error = error_message
        end
      end
    end
    
    # Examine tool calls for special cases like get_url with URL as a separate tool call
    # @param tool_calls [Array] The raw tool calls from the streaming response
    def examine_tool_calls_for_special_cases(tool_calls)
      return unless tool_calls.is_a?(Array)
      
      # Look for get_url tools without URL
      get_url_tools = tool_calls.select { |tc| tc.dig("function", "name") == "get_url" }
      
      # Look for URL in other tool calls
      url_tools = tool_calls.select do |tc| 
        function_args = tc.dig("function", "arguments") || "{}"
        args = begin
          JSON.parse(function_args) rescue {}
        end
        tc.dig("function", "name") != "get_url" && args["url"].present?
      end
      
      # If we found both a get_url tool and a tool with a URL, store the URL
      if get_url_tools.any? && url_tools.any?
        url_tool = url_tools.first
        function_args = url_tool.dig("function", "arguments") || "{}"
        args = begin
          JSON.parse(function_args) rescue {}
        end
        
        @special_url_input = args["url"] if args["url"].present?
        
        Rails.logger.debug("Found special case: get_url tool and a URL in another tool: #{@special_url_input}")
      end
    end
    
    # Handle the special case of a get_url tool where the URL is in a separate tool call
    # @return [Boolean] Whether a dangerous tool was encountered
    def handle_special_url_tool
      return false unless @special_url_input
      
      Rails.logger.debug("Creating special get_url tool with URL: #{@special_url_input}")
      
      # Create a tool use for get_url with the URL from the other tool
      saved_tool_use = @current_message.tool_uses.create!(
        name: "get_url",
        input: { "url" => @special_url_input },
        tool_use_id: SecureRandom.uuid
      )
      
      # Process this tool
      dangerous_tool = false
      if saved_tool_use.dangerous?
        saved_tool_use.update(status: :pending)
        @conversation.update(status: :waiting)
        dangerous_tool = true
      else
        saved_tool_use.update(status: :approved)
        execute_tool(saved_tool_use)
        @tool_results_pending = true
      end
      
      # Clear the special URL input
      @special_url_input = nil
      
      dangerous_tool
    end
    
    # Process tool calls detected during streaming
    # @param tool_calls [Array] Array of tool call definitions
    # @return [Boolean] Whether a dangerous tool was encountered
    def process_tool_calls(tool_calls)
      return false unless tool_calls.is_a?(Array) && tool_calls.any?
      
      Rails.logger.info("Processing #{tool_calls.count} tool calls")
      dangerous_tool_encountered = false
      
      # First, see if we can find any get_url tool and tool with URL parameter
      get_url_tool = tool_calls.find { |tc| tc["name"] == "get_url" }
      url_tool = tool_calls.find do |tc| 
        tc["input"].is_a?(Hash) && tc["input"]["url"].present? && tc["name"] != "get_url"
      end
      
      # If we found both, combine them
      if get_url_tool && url_tool && get_url_tool["input"].empty?
        get_url_tool["input"] = { "url" => url_tool["input"]["url"] }
        
        # Remove the URL tool from the list
        tool_calls = tool_calls.reject { |tc| tc == url_tool }
      end

      # Now process each valid tool call
      tool_calls.each do |tool_use|
        next unless tool_use.is_a?(Hash)
        
        # Skip if we've already processed this tool_call_id
        if tool_use['id'].present? && @processed_tool_call_ids.include?(tool_use['id'])
          next
        end
        
        # Add to processed IDs if we have an ID
        @processed_tool_call_ids << tool_use['id'] if tool_use['id'].present?
        
        # Skip tools with nil names
        if tool_use['name'].nil?
          Rails.logger.warn("Skipping tool call without a name: #{tool_use.inspect}")
          next
        end
        
        # Skip unknown_tool (we handle these specially)
        next if tool_use['name'] == 'unknown_tool'
        
        # Log tool use for debugging
        Rails.logger.debug("Processing streamed tool use: #{tool_use.inspect}")
        
        name = tool_use['name']
        input = tool_use['input'] || {}
        id = tool_use['id'] || SecureRandom.uuid
        
        # Special handling for get_url with empty input, when we have a special URL
        if name == "get_url" && input.empty? && @special_url_input.present?
          input = { "url" => @special_url_input }
          @special_url_input = nil
        end
        
        # Log the extracted data
        Rails.logger.debug("Tool name: #{name}")
        Rails.logger.debug("Tool input: #{input.inspect}")
        Rails.logger.debug("Tool ID: #{id}")
        
        # Check if this tool is already registered for this message
        existing_tool_use = @current_message.tool_uses.find_by(name: name)
        if existing_tool_use
          Rails.logger.debug("Tool use with name #{name} already exists, updating")
          existing_tool_use.update(input: input)
          saved_tool_use = existing_tool_use
        else
          saved_tool_use = @current_message.tool_uses.create!(
            name: name,
            input: input,
            tool_use_id: id,
          )
        end
        
        # Only process the tool use if it doesn't have a result yet
        if saved_tool_use.tool_result.nil?
          tool_list = @tools || []
          if tool_list.any? { |tool| tool[:name] == name }
            if saved_tool_use.dangerous?
              saved_tool_use.update(status: :pending)
              dangerous_tool_encountered = true
              @conversation.update(status: :waiting)
            else
              saved_tool_use.update(status: :approved)
              execute_tool(saved_tool_use)
              @tool_results_pending = true
            end
          else
            rejection_message = "The tool '#{name}' is not available in the current context. Please use only the tools provided in the system prompt."
            saved_tool_use.reject_with_message(rejection_message)
          end
        end
      end
      
      # Check for special case: we have a URL but no get_url tool
      if @special_url_input && !@current_message.tool_uses.exists?(name: "get_url") && !dangerous_tool_encountered
        dangerous_tool = handle_special_url_tool
        dangerous_tool_encountered ||= dangerous_tool
      end
      
      if @tool_results_pending
        Rails.logger.info("Tool results are pending after processing tools")
      else
        Rails.logger.info("No tool results are pending after processing tools")
      end
      
      dangerous_tool_encountered
    end
    
    # Execute a tool
    # @param tool_use [ToolUse] The tool use record to execute
    # @return [Boolean] Success status
    def execute_tool(tool_use)
      # Find the tool class
      Rails.logger.info("Executing tool: #{tool_use.name}")
      tool_class = @tool_classes.find { |tool| tool.definition[:name] == tool_use.name }
      
      # If tool class wasn't found in the specific ones, check the global registry
      unless tool_class
        tool_registry_class = LlmToolkit::ToolRegistry.find_tool(tool_use.name)
        if tool_registry_class
          Rails.logger.info("Found tool in global registry: #{tool_use.name}")
          tool_class = tool_registry_class
        else
          Rails.logger.warn("Tool class not found for #{tool_use.name}")
          return false
        end
      end
      
      begin
        # Log the tool definition for debugging
        #Rails.logger.info("Tool definition for #{tool_class}: #{tool_class.definition}")
        
        # Execute the tool
        result = tool_class.execute(conversable: @conversable, args: tool_use.input, tool_use: tool_use)
        
        # Handle tool execution errors
        if result.is_a?(Hash) && result[:error].present?
          tool_use.reject_with_message(result[:error])
          return false
        end
        
        # Handle asynchronous results
        if result.is_a?(Hash) && result[:state] == "asynchronous_result"
          # For async tools, the tool_use is already in an approved state
          # but the tool_result will be updated later when the async response arrives
          tool_result = tool_use.create_tool_result!(
            message: tool_use.message,
            content: result[:result],
            pending: true
          )
          return true
        end
        
        # Create a tool result with the executed tool's result
        tool_result = tool_use.create_tool_result!(
          message: tool_use.message,
          content: result.to_s
        )
        
        Rails.logger.info("Tool executed successfully: #{tool_use.name}")
        true
      rescue => e
        # Log the error
        Rails.logger.error("Error executing tool #{tool_use.name}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        
        # Create a tool result with the error
        tool_use.create_tool_result!(
          message: tool_use.message,
          content: "Error executing tool: #{e.message}",
          is_error: true
        )
        
        false
      end
    end

    # Create a new empty message for the follow-up response
    # This is needed internally when tools are executed and a new LLM call is made.
    def create_empty_message
      @conversation.messages.create!(
        role: 'assistant',
        content: '', # Start empty
        # llm_model: @llm_model, # Removed association
        user_id: @user_id # Ensure user_id is associated if available
      )
    end
  end
end
