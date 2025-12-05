# LlmToolkit configuration
LlmToolkit.configure do |config|
  # Define which tools require manual approval before execution
  # These tools will pause the conversation and require user approval
  config.dangerous_tools = [
    "write_to_file",
    "execute_command"
  ]
  
  # Default model to use for Anthropic API calls
  # You can override this per LlmProvider using the settings field
  config.default_anthropic_model = "claude-3-7-sonnet-20250219"
  
  # Default maximum tokens to generate in responses
  #config.default_max_tokens = 8192
  
  # Referer URL for OpenRouter API calls
  config.referer_url = "http://localhost:3000"
end