module LlmToolkit
  class LlmModel < ApplicationRecord
    belongs_to :llm_provider, class_name: 'LlmToolkit::LlmProvider'
    has_many :messages, class_name: 'LlmToolkit::Message', dependent: :nullify

    validates :name, presence: true, uniqueness: { scope: :llm_provider_id }

    # Scopes
    scope :ordered, -> { order(position: :asc, id: :asc) }

    # settings is a jsonb column that holds per-model feature flags.
    # Supported keys:
    #   'code_execution' (Boolean) — enable Anthropic's Code Execution native tool
    #
    # Example:
    #   model.update!(settings: { 'code_execution' => true })
    #   model.code_execution_enabled?  # => true
    def code_execution_enabled?
      settings&.dig('code_execution') == true
    end
  end
end
