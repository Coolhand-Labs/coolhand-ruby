# frozen_string_literal: true

require "net/http"
require "json"

module Coolhand
  module Ruby
    # Net::HTTP interceptor for capturing request metadata and response headers
    # This uses a prepend pattern to intercept HTTP requests at the Net::HTTP level
    module NetHttpInterceptor
      def self.patched?
        @patched ||= false
      end

      def self.patch!
        return if patched?
        return unless Coolhand.configuration.patch_net_http

        Net::HTTP.prepend(self)
        @patched = true
        Coolhand.log "🔗 Net::HTTP interceptor patched"
      end

      def self.unpatch!
        # NOTE: prepend cannot be easily unpatched
        @patched = false
      end

      def request(req, body = nil)
        start_time = Time.now
        request_id = generate_request_id

        # Only intercept requests to our target addresses
        return super unless should_intercept_request?(req)

        Coolhand.log "🌐 Intercepting Net::HTTP request to #{req.uri || "#{use_ssl? ? 'https' : 'http'}://#{address}:#{port}#{req.path}"}"

        # Store request metadata for correlation
        store_request_metadata(request_id, req, body, start_time)

        # Execute the original request
        response = super

        # Capture response metadata
        capture_response_metadata(request_id, response, start_time)

        response
      rescue StandardError => e
        # Log error metadata if needed
        log_error_metadata(request_id, e, start_time)
        raise
      end

      private

      def should_intercept_request?(req)
        uri = req.uri || URI("#{use_ssl? ? 'https' : 'http'}://#{address}:#{port}#{req.path}")
        host = uri.host

        Coolhand.configuration.intercept_addresses.any? do |addr|
          host&.include?(addr) || addr.include?(host.to_s)
        end
      end

      def generate_request_id
        "req_#{SecureRandom.hex(8)}"
      end

      def store_request_metadata(request_id, req, body, start_time)
        uri = req.uri || URI("#{use_ssl? ? 'https' : 'http'}://#{address}:#{port}#{req.path}")

        # Parse request body if it's JSON
        parsed_body = nil
        if body
          begin
            parsed_body = JSON.parse(body)
          rescue JSON::ParserError
            parsed_body = body.to_s
          end
        end

        request_data = {
          id: request_id,
          timestamp: start_time,
          method: req.method.downcase.to_sym,
          url: uri.to_s,
          headers: extract_headers(req),
          request_body: parsed_body,
          phase: "request"
        }

        # Send request metadata to Coolhand
        send_to_coolhand(request_data)
      end

      def capture_response_metadata(request_id, response, start_time)
        end_time = Time.now

        response_data = {
          id: request_id,
          timestamp: end_time,
          status_code: response.code.to_i,
          response_headers: extract_response_headers(response),
          duration_ms: ((end_time - start_time) * 1000).round(2),
          phase: "response_metadata"
        }

        # Extract request-id from response headers for correlation
        response_data[:correlation_id] = response["request-id"] if response["request-id"]

        # Send response metadata to Coolhand
        send_to_coolhand(response_data)
      end

      def log_error_metadata(request_id, error, start_time)
        end_time = Time.now

        error_data = {
          id: request_id,
          timestamp: end_time,
          status_code: 500,
          error: error.message,
          duration_ms: ((end_time - start_time) * 1000).round(2),
          phase: "error"
        }

        # Try to extract correlation ID from error if it contains response info
        if error.message.include?("request_id")
          correlation_match = error.message.match(/request_id[":]\s*["']?([^"',\s}]+)/)
          error_data[:correlation_id] = correlation_match[1] if correlation_match
        end

        send_to_coolhand(error_data)
      end

      def extract_headers(req)
        headers = {}
        req.each_header do |key, value|
          # Redact sensitive headers
          headers[key] = if key.downcase.include?("key") || key.downcase.include?("auth") || key.downcase.include?("token")
            "[REDACTED]"
          else
            value
          end
        end
        headers
      end

      def extract_response_headers(response)
        headers = {}
        response.each_header do |key, value|
          headers[key] = value
        end
        headers
      end

      def send_to_coolhand(data)
        Thread.new do
          Coolhand.logger_service.log_to_api(data)
          Coolhand.log "✅ Sent #{data[:phase]} metadata to Coolhand (ID: #{data[:id]})"
        rescue StandardError => e
          Coolhand.log "❌ Failed to send #{data[:phase]} metadata to Coolhand: #{e.message}"
        end
      end
    end
  end
end
