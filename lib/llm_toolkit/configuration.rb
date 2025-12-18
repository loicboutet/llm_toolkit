module LlmToolkit
  class Configuration
    # Tool and API settings
    attr_accessor :dangerous_tools
    attr_accessor :default_anthropic_model
    attr_accessor :default_openrouter_model
    attr_accessor :default_max_tokens
    attr_accessor :referer_url
    
    # Prompt caching configuration
    attr_accessor :enable_prompt_caching
    attr_accessor :cache_text_threshold  # Minimum characters to mark for caching

    # Streaming configuration
    attr_accessor :streaming_throttle_ms       # Throttle interval for broadcast updates (milliseconds)
    attr_accessor :max_tool_followups          # Maximum number of tool followup calls to prevent infinite loops
    
    # Content limits
    attr_accessor :max_tool_result_size        # Maximum characters for tool results in conversation history
    
    # Placeholder markers for streaming messages (used to detect "thinking" state)
    attr_accessor :placeholder_markers

    def initialize
      @dangerous_tools = []
      @default_anthropic_model = "claude-3-7-sonnet-20250219"
      @default_openrouter_model = "anthropic/claude-3-sonnet"
      @default_max_tokens = 8192
      @referer_url = "http://localhost:3000"
      
      # Prompt caching defaults
      @enable_prompt_caching = true
      @cache_text_threshold = 2048  # ~500 tokens minimum for effective caching

      # Streaming defaults
      @streaming_throttle_ms = 50
      @max_tool_followups = 100
      
      # Content limits
      @max_tool_result_size = 50_000
      
      # Default placeholder markers (French UI)
      @placeholder_markers = [
        "🤔 Traitement de votre demande...",
        "🎯 Analyse automatique en cours..."
      ].freeze
    end
    
    # Helper to check if content is a placeholder
    # Uses pure Ruby methods to avoid Rails dependency in the core check
    def placeholder_content?(content)
      return true if content.nil? || content.to_s.strip.empty?
      placeholder_markers.any? { |marker| content.to_s.strip == marker }
    end
  end
end
