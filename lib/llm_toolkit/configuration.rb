module LlmToolkit
  class Configuration
    attr_accessor :dangerous_tools
    attr_accessor :default_anthropic_model
    attr_accessor :default_openrouter_model
    attr_accessor :default_max_tokens
    attr_accessor :referer_url
    
    # Prompt caching configuration
    attr_accessor :enable_prompt_caching
    attr_accessor :cache_text_threshold  # Minimum characters to mark for caching

    def initialize
      @dangerous_tools = []
      @default_anthropic_model = "claude-3-7-sonnet-20250219"
      @default_openrouter_model = "anthropic/claude-3-sonnet"
      #@default_max_tokens = 8192
      @referer_url = "http://localhost:3000"
      
      # Prompt caching defaults
      @enable_prompt_caching = true
      @cache_text_threshold = 2048  # ~500 tokens minimum for effective caching
    end
  end
end
