# Ensure Turbo::StreamsChannel is available
require 'turbo-rails' 

module LlmToolkit
  class CallStreamingLlmWithToolService
    # Placeholder markers to detect "thinking" messages
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
      @llm_provider = @llm_model.llm_provider
      @conversation = conversation
      @assistant_message = assistant_message
      @conversable = conversation.conversable
      @user_id = user_id
      @tool_classes = tool_classes

      # Use passed tool classes or get from ToolService
      @tools = if tool_classes.any?
        ToolService.build_tool_definitions(tool_classes)
      else
        ToolService.tool_definitions
      end
      
      # Initialize variables to track streamed content using the passed message
      @current_message = @assistant_message
      
      # Check if the initial content is a placeholder that should be cleared
      initial_content = @current_message.content || ""
      @is_placeholder_content = PLACEHOLDER_MARKERS.any? { |marker| initial_content.include?(marker) }
      
      # If it's a placeholder, start with empty content (will be replaced on first chunk)
      # Otherwise, keep the existing content for appending
      @current_content = @is_placeholder_content ? "" : initial_content
      
      @content_complete = false
      @content_chunks_received = !@is_placeholder_content && initial_content.present?
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
      
      # Track pending usage data to apply to correct message
      @pending_usage_for_message = nil
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
        
        Rails.logger.info("[STREAMING SERVICE] stream_llm completed normally")

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
        Rails.logger.info("[STREAMING SERVICE] Entering ensure block, tool_results_pending=#{@tool_results_pending}")
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
      conv_history = @conversation.history(llm_model: @llm_model)
      
      # IMPORTANT: Capture the message that will receive usage data BEFORE streaming
      # This ensures tokens go to the correct message even if followup_with_tools changes @current_message
      message_for_usage = @current_message
      
      Rails.logger.info("[STREAM_LLM] Starting stream_chat call")
      
      # Call the LLM provider with streaming and handle each chunk
      final_response = @llm_provider.stream_chat(sys_prompt, conv_history, @tools, llm_model: @llm_model) do |chunk|
        process_chunk(chunk)
      end

      Rails.logger.info("[STREAM_LLM] stream_chat returned, tool_results_pending=#{@tool_results_pending}")

      # Update the message that was active at the START of this stream with usage data
      # Use message_for_usage, NOT @current_message (which may have changed during followup)
      update_message_usage_from_response(final_response, message_for_usage)

      Rails.logger.info("[STREAM_LLM] After update_message_usage_from_response, tool_results_pending=#{@tool_results_pending}")

      # Update the finish_reason from the final response if we don't have one from streaming
      if final_response && final_response['finish_reason'] && @finish_reason.nil?
        @finish_reason = final_response['finish_reason']
        message_for_usage.update(finish_reason: @finish_reason)
        Rails.logger.info("Updated finish_reason from final response: #{@finish_reason}")
      end

      # Final processing happens within the 'finish' chunk handler now.
      if final_response && final_response['tool_calls'].present? && !@content_chunks_received && @accumulated_tool_calls.empty?
        Rails.logger.warn("Processing tool calls from final_response as no streaming chunks were processed.")
        formatted_tool_calls = @llm_provider.send(:format_tools_response_from_openrouter, final_response['tool_calls'])
        dangerous_encountered = process_tool_calls(formatted_tool_calls)

        if !dangerous_encountered && @tool_results_pending
          sleep(0.5) 
          Rails.logger.info("Making follow-up call to LLM with tool results from final response")
          followup_with_tools
        end
      end

      # Special case: If we collected a URL input but haven't created a get_url tool yet
      if @special_url_input && !message_for_usage.tool_uses.exists?(name: "get_url")
        dangerous_encountered = handle_special_url_tool
        
        if !dangerous_encountered && @tool_results_pending
          sleep(0.5)
          Rails.logger.info("Making follow-up call to LLM with tool results from special URL")
          followup_with_tools
        end
      end

      # Check if we have any tool results but haven't done a follow-up yet
      # This is the main check that triggers followup after tools were processed during streaming
      Rails.logger.info("End of stream_llm - Tool results pending: #{@tool_results_pending}, Conversation waiting: #{@conversation.waiting?}")
      if @tool_results_pending && !@conversation.waiting?
        sleep(0.5)
        Rails.logger.info("Making follow-up call to LLM after end of streaming")
        followup_with_tools
      end
      
      Rails.logger.info("[STREAM_LLM] Exiting stream_llm method")
    end

    # Update message with usage data from the API response
    # Supports both standard OpenRouter usage format and cache-related tokens
    # 
    # OpenRouter returns cache tokens in different formats depending on the provider:
    # - Anthropic Claude: cache_creation_input_tokens, cache_read_input_tokens
    # - Some models: native_tokens_cached (via generation endpoint)
    #
    # @param response [Hash] The API response containing usage data
    # @param message [Message] The message to update
    def update_message_usage_from_response(response, message)
      return unless response && message
      
      usage = response['usage']
      
      # Log raw response for debugging
      Rails.logger.info("[TOKEN USAGE] Raw response keys: #{response.keys.inspect}")
      Rails.logger.info("[TOKEN USAGE] Usage data: #{usage.inspect}")
      Rails.logger.info("[TOKEN USAGE] Applying to message ##{message.id}")
      
      return unless usage
      
      # Build update hash with standard tokens
      update_data = {
        prompt_tokens: usage['prompt_tokens'].to_i,
        completion_tokens: usage['completion_tokens'].to_i,
        api_total_tokens: usage['total_tokens'].to_i
      }
      
      # === CACHE TOKEN EXTRACTION ===
      cache_creation = extract_cache_creation_tokens(usage)
      cache_read = extract_cache_read_tokens(usage)
      
      if cache_creation > 0
        update_data[:cache_creation_input_tokens] = cache_creation
        Rails.logger.info("[TOKEN USAGE] Cache creation tokens: #{cache_creation}")
      end
      
      if cache_read > 0
        update_data[:cache_read_input_tokens] = cache_read
        Rails.logger.info("[TOKEN USAGE] Cache read tokens: #{cache_read}")
      end
      
      # Update the message record
      message.update!(update_data)
      
      # Log comprehensive usage summary
      log_usage_summary(message.id, update_data, response)
      
      Rails.logger.info("[TOKEN USAGE] update_message_usage_from_response completed")
    end
    
    # Extract cache creation tokens from various response formats
    # @param usage [Hash] The usage data from the response
    # @return [Integer] Number of cache creation tokens
    def extract_cache_creation_tokens(usage)
      return 0 unless usage
      
      # Try different field names used by OpenRouter/providers
      cache_creation = usage['cache_creation_input_tokens'] ||
                       usage['cache_write_input_tokens'] ||
                       usage.dig('prompt_tokens_details', 'cached_tokens_creation') ||
                       0
      
      cache_creation.to_i
    end
    
    # Extract cache read tokens from various response formats
    # @param usage [Hash] The usage data from the response
    # @return [Integer] Number of cache read tokens
    def extract_cache_read_tokens(usage)
      return 0 unless usage
      
      # Try different field names used by OpenRouter/providers
      cache_read = usage['cache_read_input_tokens'] ||
                   usage['cached_tokens'] ||
                   usage.dig('prompt_tokens_details', 'cached_tokens') ||
                   0
      
      cache_read.to_i
    end
    
    # Log a comprehensive summary of token usage including cache statistics
    # @param message_id [Integer] The message ID
    # @param update_data [Hash] The data being saved
    # @param response [Hash] The full API response
    def log_usage_summary(message_id, update_data, response)
      prompt_tokens = update_data[:prompt_tokens] || 0
      completion_tokens = update_data[:completion_tokens] || 0
      total_tokens = update_data[:api_total_tokens] || 0
      cache_creation = update_data[:cache_creation_input_tokens] || 0
      cache_read = update_data[:cache_read_input_tokens] || 0
      
      # Basic usage log
      Rails.logger.info("[LLM USAGE] Message ##{message_id}: " \
                        "prompt=#{prompt_tokens}, completion=#{completion_tokens}, total=#{total_tokens}")
      
      # Cache-specific logging
      if cache_creation > 0 || cache_read > 0
        cache_hit_rate = prompt_tokens > 0 ? ((cache_read.to_f / prompt_tokens) * 100).round(1) : 0
        
        Rails.logger.info("[CACHE STATS] Message ##{message_id}: " \
                          "cache_creation=#{cache_creation}, " \
                          "cache_read=#{cache_read}, " \
                          "cache_hit_rate=#{cache_hit_rate}%")
        
        # Estimate savings (Anthropic: ~90% discount on cached reads)
        if cache_read > 0
          estimated_savings_tokens = (cache_read * 0.9).round
          Rails.logger.info("[CACHE SAVINGS] Estimated #{estimated_savings_tokens} tokens saved via cache")
        end
      end
      
      # Log cache discount if available from OpenRouter
      if response['cache_discount'].present?
        discount_percent = (response['cache_discount'].to_f * 100).round(1)
        Rails.logger.info("[CACHE DISCOUNT] #{discount_percent}% discount applied")
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
      
      # Reset streaming variables for this followup
      @current_content = ""
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
      conv_history = @conversation.history(llm_model: @llm_model)

      Rails.logger.debug("Follow-up conversation history size: #{conv_history.size}")
      
      # Create a new message for the followup response, associated with the model
      @current_message = create_empty_message
      
      # IMPORTANT: Capture the message for this followup BEFORE streaming
      message_for_usage = @current_message

      begin
        # Call the LLM provider with streaming and handle each chunk
        final_response = @llm_provider.stream_chat(sys_prompt, conv_history, @tools, llm_model: @llm_model) do |chunk|
          process_chunk(chunk)
        end

        Rails.logger.info("[FOLLOWUP] stream_chat returned, tool_results_pending=#{@tool_results_pending}")

        # Update the message that was active at the START of this followup with usage data
        update_message_usage_from_response(final_response, message_for_usage)

        # Update the finish_reason from the final response if we don't have one from streaming
        if final_response && final_response['finish_reason'] && @finish_reason.nil?
          @finish_reason = final_response['finish_reason']
          message_for_usage.update(finish_reason: @finish_reason)
          Rails.logger.info("Updated finish_reason from final response: #{@finish_reason}")
        end

        # Handle any tool calls in the final response (fallback if streaming didn't capture them)
        if final_response && final_response['tool_calls'].present? && !@content_chunks_received && @accumulated_tool_calls.empty?
          Rails.logger.info("[FOLLOWUP] Processing tool calls from final_response")
          formatted_tool_calls = @llm_provider.send(:format_tools_response_from_openrouter, final_response['tool_calls'])
          dangerous_encountered = process_tool_calls(formatted_tool_calls)
          
          if !dangerous_encountered && @tool_results_pending
            sleep(0.5)
            Rails.logger.info("[FOLLOWUP] Making recursive follow-up call after final_response tool calls")
            followup_with_tools
            return # Important: return after recursive call to avoid duplicate checks
          end
        end
        
        # CRITICAL FIX: Check if we have tool results pending from streaming
        # This handles the case where tools were processed during the 'finish' chunk
        Rails.logger.info("[FOLLOWUP] End of followup - Tool results pending: #{@tool_results_pending}, Conversation waiting: #{@conversation.waiting?}")
        if @tool_results_pending && !@conversation.waiting?
          sleep(0.5)
          Rails.logger.info("[FOLLOWUP] Making follow-up call after tool execution during streaming")
          followup_with_tools
          return # Important: return after recursive call
        end
        
        # Check for multi-step tool interactions (LLM text indicates it wants to use tools)
        if @current_message.content.present? && !@conversation.waiting? && 
           looks_like_attempting_tool_use(@current_message.content)
          Rails.logger.info("[FOLLOWUP] LLM appears to be attempting to use tools again based on content.")
          @tool_results_pending = true
          sleep(0.5)
          followup_with_tools
          return
        end
        
        Rails.logger.info("[FOLLOWUP] Followup ##{@followup_count} completed without needing further followup")
        
      rescue => e
        error_message = "Error in followup call: #{e.message}"
        Rails.logger.error(error_message)
        Rails.logger.error(e.backtrace.join("\n"))
        
        friendly_message = case e.message
        when /Status 413/i
          "La conversation est devenue trop longue. Veuillez commencer une nouvelle conversation."
        when /Status 400/i
          "Une erreur de format s'est produite. Veuillez réessayer."
        when /Status 429/i, /rate limit/i
          "Le service est temporairement surchargé. Veuillez réessayer dans quelques instants."
        when /timeout/i
          "La requête a pris trop de temps. Veuillez réessayer."
        else
          "Une erreur s'est produite: #{e.message.truncate(100)}"
        end
        
        if @current_message
          @current_message.update(
            content: friendly_message,
            is_error: true,
            finish_reason: 'error'
          )
        end
      end
    end
    
    # Check if the message content looks like it's attempting to use a tool
    def looks_like_attempting_tool_use(content)
      patterns = [
        /I('ll)? (need to|should|will|want to) use/i,
        /Let('s| me)? use the/i,
        /I('ll)? search for/i,
        /I('ll)? need to (search|check|read|fetch)/i,
        /Using the .* tool/i,
        /Let('s| me)? (search|fetch|check|analyze)/i,
        /I'll (call|execute|invoke|use)/i,
        /I need to (call|execute|invoke|use)/i,
        /Je vais (utiliser|rechercher|lire|analyser)/i,
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

          # Update the database record - this will trigger the efficient broadcast_content_update
          if @current_message
            @current_message.update(content: @current_content)
          else
            Rails.logger.error("Cannot update content: current_message is nil")
          end

        when 'error'
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
              next unless index.is_a?(Integer)

              @accumulated_tool_calls[index] ||= {}
              begin
                @accumulated_tool_calls[index].deep_merge!(partial_tool_call)
              rescue => e
                Rails.logger.error("Error merging tool call: #{e.message}")
              end
            end
          else
            Rails.logger.error("Invalid tool_calls format: #{chunk[:tool_calls].inspect}")
          end

        when 'finish'
          @content_complete = true
          
          if chunk[:finish_reason].present?
            @finish_reason = chunk[:finish_reason]
            Rails.logger.info("Extracted finish_reason from chunk: #{@finish_reason}")
            @current_message.update(finish_reason: @finish_reason) if @current_message
          end

          # If we accumulated tool calls, process them
          # NOTE: We process tool calls here but do NOT immediately call followup_with_tools
          # The followup happens AFTER the streaming method returns and usage is recorded
          unless @accumulated_tool_calls.empty?
            complete_tool_calls = @accumulated_tool_calls.values.sort_by { |tc| tc['index'] || 0 }
            Rails.logger.debug "Accumulated complete tool calls: #{complete_tool_calls.inspect}"

            examine_tool_calls_for_special_cases(complete_tool_calls)

            formatted_tool_calls = @llm_provider.send(:format_tools_response_from_openrouter, complete_tool_calls)
            Rails.logger.debug "Formatted tool calls for processing: #{formatted_tool_calls.inspect}"

            process_tool_calls(formatted_tool_calls)
            
            # Mark that followup is needed, but DON'T call it here
            # This allows the calling method (stream_llm or followup_with_tools) to record usage first
            Rails.logger.info("Tool results pending: #{@tool_results_pending}, waiting: #{@conversation.waiting?}")
          end
          @accumulated_tool_calls = {}
        else
          Rails.logger.warn("Unknown chunk type: #{chunk[:chunk_type]}")
        end
      rescue => e
        error_message = "Error processing chunk: #{e.message}"
        
        unless error_message == @last_error
          Rails.logger.error(error_message)
          Rails.logger.error(e.backtrace.join("\n"))
          Rails.logger.error("Chunk that caused error: #{chunk.inspect}")
          @last_error = error_message
        end
      end
    end
    
    # Examine tool calls for special cases like get_url with URL as a separate tool call
    def examine_tool_calls_for_special_cases(tool_calls)
      return unless tool_calls.is_a?(Array)
      
      get_url_tools = tool_calls.select { |tc| tc.dig("function", "name") == "get_url" }
      
      url_tools = tool_calls.select do |tc| 
        function_args = tc.dig("function", "arguments") || "{}"
        args = begin
          JSON.parse(function_args) rescue {}
        end
        tc.dig("function", "name") != "get_url" && args["url"].present?
      end
      
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
    def handle_special_url_tool
      return false unless @special_url_input
      
      Rails.logger.debug("Creating special get_url tool with URL: #{@special_url_input}")
      
      saved_tool_use = @current_message.tool_uses.create!(
        name: "get_url",
        input: { "url" => @special_url_input },
        tool_use_id: SecureRandom.uuid
      )
      
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
      
      @special_url_input = nil
      
      dangerous_tool
    end
    
    # Process tool calls detected during streaming
    def process_tool_calls(tool_calls)
      return false unless tool_calls.is_a?(Array) && tool_calls.any?
      
      Rails.logger.info("Processing #{tool_calls.count} tool calls")
      dangerous_tool_encountered = false
      
      get_url_tool = tool_calls.find { |tc| tc["name"] == "get_url" }
      url_tool = tool_calls.find do |tc| 
        tc["input"].is_a?(Hash) && tc["input"]["url"].present? && tc["name"] != "get_url"
      end
      
      if get_url_tool && url_tool && get_url_tool["input"].empty?
        get_url_tool["input"] = { "url" => url_tool["input"]["url"] }
        tool_calls = tool_calls.reject { |tc| tc == url_tool }
      end

      tool_calls.each do |tool_use|
        next unless tool_use.is_a?(Hash)
        
        if tool_use['id'].present? && @processed_tool_call_ids.include?(tool_use['id'])
          next
        end
        
        @processed_tool_call_ids << tool_use['id'] if tool_use['id'].present?
        
        if tool_use['name'].nil?
          Rails.logger.warn("Skipping tool call without a name: #{tool_use.inspect}")
          next
        end
        
        next if tool_use['name'] == 'unknown_tool'
        
        Rails.logger.debug("Processing streamed tool use: #{tool_use.inspect}")
        
        name = tool_use['name']
        input = tool_use['input'] || {}
        id = tool_use['id'] || SecureRandom.uuid
        
        if name == "get_url" && input.empty? && @special_url_input.present?
          input = { "url" => @special_url_input }
          @special_url_input = nil
        end
        
        Rails.logger.debug("Tool name: #{name}")
        Rails.logger.debug("Tool input: #{input.inspect}")
        Rails.logger.debug("Tool ID: #{id}")
        
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
    def execute_tool(tool_use)
      Rails.logger.info("Executing tool: #{tool_use.name}")
      tool_class = @tool_classes.find { |tool| tool.definition[:name] == tool_use.name }
      
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
        result = tool_class.execute(conversable: @conversable, args: tool_use.input, tool_use: tool_use)
        
        if result.is_a?(Hash) && result[:error].present?
          tool_use.reject_with_message(result[:error])
          return false
        end
        
        if result.is_a?(Hash) && result[:skip_tool_result]
          Rails.logger.info("Tool #{tool_use.name} returned skip_tool_result - tool_result will be created later")
          return true
        end
        
        if result.is_a?(Hash) && result[:state] == "asynchronous_result"
          tool_result = tool_use.create_tool_result!(
            message: tool_use.message,
            content: result[:result],
            pending: true
          )
          return true
        end
        
        tool_result = tool_use.create_tool_result!(
          message: tool_use.message,
          content: result.to_s
        )
        
        Rails.logger.info("Tool executed successfully: #{tool_use.name}")
        true
      rescue => e
        Rails.logger.error("Error executing tool #{tool_use.name}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        
        tool_use.create_tool_result!(
          message: tool_use.message,
          content: "Error executing tool: #{e.message}",
          is_error: true
        )
        
        false
      end
    end

    # Create a new empty message for the follow-up response
    def create_empty_message
      @conversation.messages.create!(
        role: 'assistant',
        content: '',
        llm_model: @llm_model,
        user_id: @user_id
      )
    end
  end
end
