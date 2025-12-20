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

        formatted_system_messages = format_system_messages_for_openrouter(system_messages)
        fixed_conversation_history = fix_conversation_history_for_openrouter(conversation_history)
        messages = formatted_system_messages + fixed_conversation_history

        model_name = llm_model.model_id.presence || llm_model.name
        max_tokens = settings&.dig('max_tokens') || LlmToolkit.config.default_max_tokens
        Rails.logger.info("Using model: #{model_name}")
        Rails.logger.info("Max tokens : #{max_tokens}")

        request_body = {
          model: model_name,
          messages: messages,
          stream: false,
          usage: { include: true }
        }

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
          raise ApiError, "API error: #{response.body['error']&.[]('message') || response.body}"
        end
      rescue Faraday::Error => e
        Rails.logger.error("OpenRouter API error: #{e.message}")
        raise ApiError, "Network error: #{e.message}"
      end

      def stream_openrouter(llm_model, system_messages, conversation_history, tools = nil, &block)
        client = Faraday.new(url: 'https://openrouter.ai/api/v1') do |f|
          f.request :json
          f.adapter Faraday.default_adapter
          f.options.timeout = 600
          f.options.open_timeout = 10
        end

        formatted_system_messages = format_system_messages_for_openrouter(system_messages)
        fixed_conversation_history = fix_conversation_history_for_openrouter(conversation_history)
        messages = formatted_system_messages + fixed_conversation_history

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
        
        log_system_message_structure(formatted_system_messages)
        log_conversation_caching_info(fixed_conversation_history)
        
        if Rails.env.development?
          sanitized_body = sanitize_request_body_for_logging(request_body)
          Rails.logger.debug "OPENROUTER STREAMING REQUEST BODY: #{JSON.pretty_generate(sanitized_body)}"
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
        
        unless (200..299).cover?(response.status)
          error_detail = streaming_state[:api_error] || "Status #{response.status}"
          Rails.logger.error("OpenRouter API streaming error: #{error_detail}")
          raise ApiError, "API streaming error: #{error_detail}"
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
      rescue Faraday::Error => e
        Rails.logger.error("OpenRouter API streaming error: #{e.message}")
        raise ApiError, "Network error during streaming: #{e.message}"
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
          Rails.logger.info("[CONVERSATION CACHE] Tool messages in history: #{tool_message_count} (cannot have cache_control)")
        end
      end
      
      # Fix conversation history for OpenRouter API compatibility
      #
      # CACHING STRATEGY:
      # 
      # Put cache_control on the LAST non-tool message WITH ACTUAL CONTENT.
      # 
      # Why "with content"? Because assistant messages that trigger tool calls
      # often have empty content (just tool_calls array). Caching an empty
      # message doesn't cache anything useful!
      #
      # Example of the problem:
      #   msg[24]: user "do something" (50 chars)
      #   msg[25]: assistant "" + tool_calls  <- EMPTY CONTENT!
      #   msg[26]: tool result
      #
      # Old code would cache msg[25] with 0 chars = useless.
      # New code caches msg[24] with 50 chars = caches the prefix!
      def fix_conversation_history_for_openrouter(conversation_history)
        messages = Array(conversation_history)
        return [] if messages.empty?
        
        # Find the last non-tool message WITH ACTUAL CONTENT
        cache_target_idx = find_last_cacheable_message_index(messages)
        
        Rails.logger.info("[CONVERSATION CACHE] Strategy: cache LAST non-tool message WITH CONTENT")
        Rails.logger.info("[CONVERSATION CACHE] Cache target message index: #{cache_target_idx || 'NONE'}")
        
        messages.each_with_index.map do |msg, index|
          fixed_msg = msg.dup
          is_tool_message = (msg[:role] == 'tool')
          should_cache = (index == cache_target_idx) && conversation_caching_enabled?
          
          # Tool messages must have string content
          if is_tool_message
            fixed_msg[:content] = ensure_string_content(msg[:content])
            next fixed_msg
          end
          
          content = msg[:content]
          
          if content.nil?
            fixed_msg[:content] = ""
          elsif content.is_a?(String)
            if should_cache
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
      
      # Find the last message that:
      # 1. Is NOT a tool message
      # 2. HAS actual text content (not empty)
      #
      # This ensures we cache something meaningful, not an empty tool-call container
      def find_last_cacheable_message_index(messages)
        last_idx = nil
        
        messages.each_with_index do |msg, idx|
          # Skip tool messages
          next if msg[:role] == 'tool'
          
          # Check if message has actual content
          content = msg[:content]
          has_content = false
          
          if content.is_a?(String)
            has_content = content.present? && content.strip.length > 0
          elsif content.is_a?(Array)
            has_content = content.any? { |item| 
              text = get_text_from_item(item)
              text.present? && text.strip.length > 0
            }
          end
          
          # Update last_idx if this message has content
          last_idx = idx if has_content
        end
        
        # If no message with content found, fall back to last non-tool message
        if last_idx.nil?
          messages.each_with_index do |msg, idx|
            last_idx = idx unless msg[:role] == 'tool'
          end
          Rails.logger.warn("[CONVERSATION CACHE] No message with content found, falling back to last non-tool message")
        end
        
        last_idx
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
            existing_tool_call['function']['arguments'] += tool_call['function']['arguments']
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
