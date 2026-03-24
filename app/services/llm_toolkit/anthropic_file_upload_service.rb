# frozen_string_literal: true

module LlmToolkit
  # Uploads files to the Anthropic Files API and caches the resulting file_id
  # on the ActiveStorage blob so that subsequent LLM turns can reference the
  # file by id instead of re-encoding the full binary as base64 every time.
  #
  # Anthropic Files API docs:
  #   POST   https://api.anthropic.com/v1/files   (upload)
  #   GET    https://api.anthropic.com/v1/files   (list)
  #   DELETE https://api.anthropic.com/v1/files/:id
  #
  # Required beta header: anthropic-beta: files-api-2025-04-14
  #
  # Usage in a message (PDF):
  #   { type: "document", source: { type: "file", file_id: "file_xxx" } }
  #
  # Usage in a message (image):
  #   { type: "image", source: { type: "file", file_id: "file_xxx" } }
  class AnthropicFileUploadService
    FILES_API_URL  = "https://api.anthropic.com/v1/files"
    ANTHROPIC_VERSION = "2023-06-01"
    FILES_API_BETA = "files-api-2025-04-14"

    def initialize(provider)
      @provider = provider
    end

    # Returns the Anthropic file_id for the given ActiveStorage attachment.
    # Caches the id on the blob's anthropic_file_id column to avoid re-uploading.
    # Returns nil on any failure so callers can fall back to base64 inline.
    def upload_or_get_file_id(attachment)
      blob = attachment.blob

      if blob.respond_to?(:anthropic_file_id) && blob.anthropic_file_id.present?
        Rails.logger.info "[AnthropicFileUpload] Using cached file_id #{blob.anthropic_file_id} for #{blob.filename}"
        return blob.anthropic_file_id
      end

      file_id = upload_to_anthropic(attachment)

      if file_id && blob.respond_to?(:anthropic_file_id=)
        blob.update_column(:anthropic_file_id, file_id)
      end

      file_id
    rescue => e
      Rails.logger.error "[AnthropicFileUpload] Failed to upload #{attachment.filename}: #{e.message}"
      nil
    end

    private

    def upload_to_anthropic(attachment)
      file_data    = attachment.blob.download
      filename     = attachment.filename.to_s
      content_type = attachment.content_type

      conn = Faraday.new(url: "https://api.anthropic.com") do |f|
        f.request :multipart
        f.request :url_encoded
        f.response :json
        f.adapter Faraday.default_adapter
        f.options.timeout = 120
      end

      response = conn.post("/v1/files") do |req|
        req.headers["x-api-key"]        = @provider.api_key
        req.headers["anthropic-version"] = ANTHROPIC_VERSION
        req.headers["anthropic-beta"]    = FILES_API_BETA
        req.body = {
          file: Faraday::Multipart::FilePart.new(
            StringIO.new(file_data),
            content_type,
            filename
          )
        }
      end

      if response.success?
        file_id = response.body["id"]
        Rails.logger.info "[AnthropicFileUpload] Uploaded #{filename} (#{file_data.bytesize} bytes) -> file_id: #{file_id}"
        file_id
      else
        Rails.logger.error "[AnthropicFileUpload] Upload failed (#{response.status}): #{response.body.inspect}"
        nil
      end
    end
  end
end
