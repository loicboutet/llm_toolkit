module LlmToolkit
  class LlmModel < ApplicationRecord
    belongs_to :llm_provider, class_name: 'LlmToolkit::LlmProvider'
    has_many :messages, class_name: 'LlmToolkit::Message', dependent: :nullify

    validates :name, presence: true, uniqueness: { scope: :llm_provider_id }

    # Scopes
    scope :ordered, -> { order(position: :asc, id: :asc) }
  end
end
