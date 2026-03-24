# frozen_string_literal: true

module LlmToolkit
  # Service to upload files to the OpenRouter Files API and cache the resulting file_id
  # on the ActiveStorage blob so that subsequent LLM turns can reference the file by id
  # instead of re-encoding the whole binary in base64 every time.
  class OpenrouterFileUploadService
    UPLOAD_URL = "https://openrouter.ai/api/v1/files"

    def initialize(provider)
      @provider = provider
    end

    # Returns the OpenRouter file_id for the given ActiveStorage attachment.
    # If the blob already has an openrouter_file_id cached, returns it immediately.
    # Otherwise uploads the file and persists the id on the blob.
    # Returns nil on any failure so callers can fall back gracefully.
    def upload_or_get_file_id(attachment)
      blob = attachment.blob

      # Return cached file_id if already uploaded
      if blob.respond_to?(:openrouter_file_id) && blob.openrouter_file_id.present?
        Rails.logger.info "[OpenRouterFileUpload] Using cached file_id #{blob.openrouter_file_id} for #{blob.filename}"
        return blob.openrouter_file_id
      end

      file_id = upload_to_openrouter(attachment)

      # Persist the file_id on the blob for future calls
      if file_id && blob.respond_to?(:openrouter_file_id=)
        blob.update_column(:openrouter_file_id, file_id)
      end

      file_id
    rescue => e
      Rails.logger.error "[OpenRouterFileUpload] Failed to upload #{attachment.filename}: #{e.message}"
      nil
    end

    private

    def upload_to_openrouter(attachment)
      file_data    = attachment.blob.download
      filename     = attachment.filename.to_s
      content_type = attachment.content_type

      conn = Faraday.new(url: "https://openrouter.ai") do |f|
        f.request :multipart
        f.request :url_encoded
        f.response :json
        f.adapter Faraday.default_adapter
        f.options.timeout = 120
      end

      response = conn.post("/api/v1/files") do |req|
        req.headers["Authorization"] = "Bearer #{@provider.api_key}"
        req.body = {
          file: Faraday::Multipart::FilePart.new(
            StringIO.new(file_data),
            content_type,
            filename
          ),
          purpose: "assistants"
        }
      end

      if response.success?
        file_id = response.body["id"]
        Rails.logger.info "[OpenRouterFileUpload] Uploaded #{filename} -> file_id: #{file_id}"
        file_id
      else
        Rails.logger.error "[OpenRouterFileUpload] Upload failed (#{response.status}): #{response.body.inspect}"
        nil
      end
    end
  end
end
