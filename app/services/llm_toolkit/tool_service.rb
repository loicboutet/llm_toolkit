module LlmToolkit
  class ToolService
    def self.build_tool_definitions(tools)
      # Debug output to understand what's being passed
      Rails.logger.info "Building tool definitions for: #{tools.map(&:name).join(', ')}"
      
      # Get definitions and log them
      defs = tools.map do |tool|
        definition = tool.definition
        #Rails.logger.info "Tool definition for #{tool.name}: #{definition.inspect}"
        definition
      end
      
      # Return the definitions
      defs
    end
    
    def self.tool_definitions
      # Simply return an empty array when no tools are specified
      # instead of automatically collecting all tool definitions
      []
    end

    def self.execute_tool(tool_use)
      begin
        conversable = tool_use.message.conversation.conversable
        tool_class = LlmToolkit::Tools::AbstractTool.find_tool(tool_use.name)

        if tool_class
          # Ensure input is always a valid hash
          input = standardize_tool_input(tool_use.input)
                  
          # Log the execution for debugging
          Rails.logger.info("Executing tool '#{tool_use.name}' with input: #{input.inspect}")
          
          result = tool_class.execute(conversable: conversable, args: input, tool_use: tool_use)
          
          # Log the raw result for debugging
          Rails.logger.info("Tool '#{tool_use.name}' returned result: #{result.class.name}, #{result.inspect.truncate(100)}")
          
          # Check if the tool is requesting asynchronous handling
          if result.is_a?(Hash) && result[:state] == "asynchronous_result"
            Rails.logger.info("Tool #{tool_use.name} requested asynchronous result handling")
            # The tool_use will be flagged as waiting for an async result
            tool_use.update(status: :waiting)
            # Create initial result but mark it as pending
            create_tool_result(tool_use, result.merge(is_pending: true))
            # Signal to the caller that we're waiting for an async result
            return { asynchronous: true, tool_use_id: tool_use.id }
          end
        else
          result = { error: "Unknown tool: #{tool_use.name}" }
        end

        create_tool_result(tool_use, result)
      rescue => e
        Rails.logger.error("Error executing tool #{tool_use.name}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        create_tool_result(tool_use, { error: "Error executing tool: #{e.message}" })
      end
    end

    private

    # Standardize tool input to ensure it's always a properly formatted hash
    def self.standardize_tool_input(input)
      # Handle different input formats
      if input.nil? || input == ""
        return {}
      elsif input.is_a?(String)
        # Try to parse JSON string
        begin
          return JSON.parse(input)
        rescue
          # If it's not valid JSON, return as-is in a hash
          return { "input" => input }
        end
      elsif input.is_a?(Hash)
        # If it's already a hash, return it
        return input
      else
        # For any other type, convert to string and wrap in a hash
        return { "input" => input.to_s }
      end
    end

    def self.create_tool_result(tool_use, result)
      # Ensure result is a hash with expected keys
      result ||= {}
      
      # Check if this is a pending asynchronous result
      is_pending = result.delete(:is_pending) || false
      
      # Convert the result to a properly formatted string
      content = format_tool_result_content(result)
      
      # Log the formatted content for debugging
      Rails.logger.info("Tool '#{tool_use.name}' formatted content (first 100 chars): #{content.to_s[0..100]}")
      
      # Create the tool result record
      tool_result = tool_use.create_tool_result!(
        message: tool_use.message,
        content: content,
        is_error: result.key?(:error),
        diff: result[:diff],
        pending: is_pending
      )
      
      # Log success
      Rails.logger.info("Created tool result ##{tool_result.id} for tool use ##{tool_use.id}")
      
      tool_result
    rescue => e
      Rails.logger.error("Error creating tool result: #{e.message}")
      
      # Try to create a fallback result
      begin
        tool_result = tool_use.create_tool_result!(
          message: tool_use.message,
          content: "Error processing tool result: #{e.message}",
          is_error: true,
          diff: nil
        )
        Rails.logger.info("Created fallback tool result ##{tool_result.id} for tool use ##{tool_use.id}")
        tool_result
      rescue => inner_e
        Rails.logger.error("Failed to create fallback tool result: #{inner_e.message}")
        nil
      end
    end
    
    # Format the tool result content to ensure it's a valid string for OpenRouter
    # IMPORTANT: This method converts tool execution results to a string format
    # that can be sent back to the LLM. The LLM needs ALL the data, not just
    # a summary message.
    def self.format_tool_result_content(result)
      if result.is_a?(String)
        # If the result is already a string, use it directly
        return result
      elsif result.is_a?(Hash)
        if result[:error].present?
          # Handle error hash format - still include full context
          error_result = { error: result[:error] }
          # Include any additional context that might help debug
          result.except(:error).each { |k, v| error_result[k] = v }
          return JSON.pretty_generate(error_result) rescue "Error: #{result[:error]}"
        else
          # FIXED: Return the ENTIRE hash as JSON, not just the :result key
          # The LLM needs all the data (runs, workflows, pagination info, etc.)
          # not just the summary message in :result
          return JSON.pretty_generate(result) rescue result.to_json
        end
      elsif result.is_a?(Array)
        # Handle array results by converting to JSON
        return JSON.pretty_generate(result) rescue result.to_s
      elsif result.nil?
        # Handle nil result
        return "No result provided"
      else
        # Handle any other type
        return result.to_s
      end
    end
  end
end