module LlmToolkit
  # Base class for all tools using the DSL
  class ToolDSL
    class << self
      # Store descriptions for each class
      def descriptions
        @descriptions ||= {}
      end
      
      # Store parameters for each class
      def parameters
        @parameters ||= {}
      end
      
      def description(text = nil)
        if text
          descriptions[self.name] = text
        end
        descriptions[self.name] || "Tool for #{self.name}"
      end
      
      def param(name, type: :string, desc: nil, required: true)
        parameters[self.name] ||= {}
        parameters[self.name][name.to_sym] = {
          type: type,
          description: desc,
          required: required
        }
      end
      
      # Track inheritance to make sure tools are properly registered
      def inherited(subclass)
        super
        # Register with the central registry
        LlmToolkit::ToolRegistry.register(subclass)
        Rails.logger.info "Registered DSL tool: #{subclass.name}" if defined?(Rails)
      end
      
      # Convert our DSL to the schema expected by LLMs
      def definition
        result = {
          name: self.name.demodulize.underscore,
          description: description,
          input_schema: {
            type: "object",
            properties: build_properties,
            required: build_required_params
          }
        }
        #Rails.logger.debug "Tool definition for #{self.name}: #{result.inspect}" if defined?(Rails)
        result
      end
      
      # Implementation for the tool interface
      def execute(conversable:, args:, tool_use: nil)
        # Create instance
        instance = new
        
        # Prepare named parameters for the execute method
        params = {}
        class_params = parameters[self.name] || {}
        class_params.each_key do |key|
          # Convert string keys to symbols for named parameters
          params[key] = args[key.to_s] || args[key.to_sym]
        end
        
        # Call the instance method with named parameters
        result = instance.execute(conversable: conversable, tool_use: tool_use, **params)
        
        # Return the result
        result.is_a?(Hash) ? result : { result: result.to_s }
      rescue => e
        Rails.logger.error "Error executing #{self.name}: #{e.message}" if defined?(Rails)
        Rails.logger.error e.backtrace.join("\n") if defined?(Rails) && e.backtrace
        { error: "Error executing #{self.name}: #{e.message}" }
      end
      
      private
      
      def build_properties
        result = {}
        class_params = parameters[self.name] || {}
        
        class_params.each do |param_name, options|
          result[param_name.to_s] = {
            type: type_to_string(options[:type]),
            description: options[:description] || param_name.to_s
          }
        end
        result
      end
      
      def build_required_params
        class_params = parameters[self.name] || {}
        class_params.select { |_, options| options[:required] }.keys.map(&:to_s)
      end
      
      def type_to_string(type)
        case type
        when :integer, :int then "integer"
        when :boolean, :bool then "boolean"
        when :number, :float then "number"
        when :array then "array"
        when :object, :hash then "object"
        else "string"
        end
      end
    end
    
    # Instance method to be implemented by subclasses
    def execute(conversable:, tool_use:, **params)
      raise NotImplementedError, "#{self.class.name} must implement #execute"
    end
  end
end
