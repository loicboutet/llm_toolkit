module LlmToolkit
  # Base class for all LlmToolkit jobs
  # 
  # Inherits from the main application's ApplicationJob to get:
  # - Tenant context propagation (Current.tenant)
  # - Any other application-wide job configurations
  #
  # This ensures that LLM jobs have access to the correct tenant context
  # when accessing tenant-scoped data like AppSetting.current.
  #
  class ApplicationJob < ::ApplicationJob
  end
end
