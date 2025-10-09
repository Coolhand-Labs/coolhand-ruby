# frozen_string_literal: true

module Coolhand
  # Handles the formatting and sending of intercepted data to the Coolhand API.
  module Logger
    def self.log_to_api(captured_data)
      config = Coolhand.configuration

      payload = {
        llm_request_log: {
          raw_request: captured_data
        }
      }

      uri = URI.parse(config.api_endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["X-API-Key"] = config.api_key
      request.body = payload.to_json

      Coolhand.log "\n🎉 LOGGING OpenAI API Call #{uri}"
      Coolhand.log captured_data

      begin
        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          result = JSON.parse(response.body)
          Coolhand.log "✅ Successfully logged to API with ID: #{result['id']}"
        else
          Coolhand.log "❌ COOLHAND: Failed to log to API: #{response.code} - #{response.body}"
        end
      rescue StandardError => e
        Coolhand.log "❌ COOLHAND: Error logging to API: #{e.message}"
      end
    ensure
      Coolhand.log "═" * 60 unless config.silent
    end
  end
end
