# frozen_string_literal: true

module Coolhand
  # Handles the formatting and sending of intercepted data to the Coolhand API.
  module Logger
    def self.log_to_api(call_data)
      config = Coolhand.configuration

      uri = URI.parse(config.api_endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['X-API-Key'] = config.api_key
      request.body = call_data.to_json

      log_request_summary(call_data, config.api_endpoint)

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
      Coolhand.log '═' * 60 unless config.silent
    end

    def self.log_request_summary(data, endpoint)
      return if Coolhand.configuration.silent

      puts "\n🎉 LOGGING OpenAI API Call ##{data[:id]}"
      puts "🕐 Time: #{data[:timestamp]}"
      puts "🎯 #{data[:method]} #{data[:url]}"
      puts "📊 Status: #{data[:status_code]} (#{data[:duration_ms]}ms)"
      puts "🤖 Model: #{data.dig(:request_body, 'model') || 'N/A'}"
      puts "💬 Messages: #{data.dig(:request_body, 'messages')&.length || 'N/A'}"
      puts "📤 Sending to: #{endpoint}"
    end
  end
end