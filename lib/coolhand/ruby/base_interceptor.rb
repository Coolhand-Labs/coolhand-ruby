# frozen_string_literal: true

require "securerandom"
require "json"

module Coolhand
  module Ruby
    # Base module with common functionality for all interceptors
    module BaseInterceptor
      extend self

      def extract_response_data(response)
        case response
        when Hash
          response
        when Struct
          response.to_h
        else
          # Handle streaming responses - these are often enumerator objects
          # that can't be serialized directly
          if response.class.name.include?("Stream") || response.respond_to?(:each)
            {
              response_type: "streaming",
              class: response.class.name,
              note: "Streaming response - content captured during enumeration"
            }
          elsif response.respond_to?(:to_h)
            begin
              response.to_h
            rescue StandardError => e
              {
                serialization_error: e.message,
                class: response.class.name,
                raw_response: response.to_s
              }
            end
          else
            # Extract content and token usage information
            response_data = {}

            # Get content
            response_data[:content] = response.content if response.respond_to?(:content)

            # Extract token usage information
            response_data[:usage] = extract_usage_metadata(response.usage) if response.respond_to?(:usage)

            # Extract model information
            response_data[:model] = response.model if response.respond_to?(:model)

            # Extract role information
            response_data[:role] = response.role if response.respond_to?(:role)

            # Extract ID if available
            response_data[:id] = response.id if response.respond_to?(:id)

            # Extract stop reason if available
            response_data[:stop_reason] = response.stop_reason if response.respond_to?(:stop_reason)

            # Add class info for debugging
            response_data[:class] = response.class.name

            response_data.empty? ? { raw_response: response.to_s, class: response.class.name } : response_data
          end
        end
      end

      def extract_usage_metadata(usage)
        if usage.respond_to?(:to_h)
          usage.to_h
        elsif usage.is_a?(Hash)
          usage
        else
          # Extract individual usage fields
          usage_data = {}
          usage_data[:input_tokens] = usage.input_tokens if usage.respond_to?(:input_tokens)
          usage_data[:output_tokens] = usage.output_tokens if usage.respond_to?(:output_tokens)
          usage_data[:total_tokens] = usage_data[:input_tokens].to_i + usage_data[:output_tokens].to_i
          usage_data
        end
      end

      def clean_request_headers(headers)
        cleaned = headers.dup

        # Remove sensitive headers
        cleaned.delete("Authorization")
        cleaned.delete("authorization")
        cleaned.delete("x-api-key")
        cleaned.delete("X-API-Key")

        cleaned
      end

      def clean_response_headers(headers)
        # Response headers typically don't contain sensitive data
        # but we can filter if needed
        headers.dup
      end

      def sanitize_headers(headers)
        return {} if headers.nil?

        # Normalize different header-like objects into a plain Hash{String => String}
        raw = if headers.is_a?(Hash)
                headers.transform_keys(&:to_s).transform_values { |v| normalize_header_value(v) }
              elsif headers.respond_to?(:to_hash)
                # Net::HTTPResponse and some request objects implement to_hash and return arrays for values
                headers.to_hash.transform_keys(&:to_s).transform_values { |v| normalize_header_value(v) }
              elsif headers.respond_to?(:each_header)
                # Net::HTTPResponse also implements each_header
                h = {}
                headers.each_header { |k, v| h[k.to_s] = normalize_header_value(v) }
                h
              elsif headers.respond_to?(:each)
                h = {}
                headers.each { |k, v| h[k.to_s] = normalize_header_value(v) }
                h
              else
                # Fallback: preserve as raw string under 'raw' key
                { "raw" => headers.to_s }
              end

        sanitized = raw.dup

        # Redact Authorization Bearer tokens
        sanitized.each do |k, v|
          next if v.nil?

          key_down = k.to_s.downcase

          if key_down == "authorization"
            # Keep the "Bearer" prefix but redact the token; otherwise mask whole value
            if v.to_s.match?(/\ABearer\s+/i)
              sanitized[k] = v.to_s.gsub(/\ABearer\s+.+/i, "Bearer [REDACTED]")
            else
              sanitized[k] = "[REDACTED]"
            end
          elsif %w[openai-api-key api-key x-api-key x-api-key].include?(key_down)
            sanitized[k] = "[REDACTED]"
          end
        end

        sanitized
      end

      private

      # Helper to normalize header values (arrays -> joined string)
      def normalize_header_value(value)
        if value.is_a?(Array)
          value.join(", ")
        else
          value.to_s
        end
      end

      def send_complete_request_log(request_id:, method:, url:, request_headers:, request_body:, response_headers:,
        response_body:, status_code:, start_time:, end_time:, duration_ms:, is_streaming:)
        request_data = {
          raw_request: {
            id: request_id,
            timestamp: start_time.iso8601,
            method: method.to_s.downcase,
            url: url,
            headers: request_headers,
            request_body: request_body,
            response_headers: response_headers,
            response_body: response_body,
            status_code: status_code,
            duration_ms: duration_ms,
            completed_at: end_time.iso8601,
            is_streaming: is_streaming
          }
        }

        api_service = Coolhand::Ruby::ApiService.new
        api_service.send_llm_request_log(request_data)

        Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
      rescue StandardError => e
        Coolhand.log "❌ Error sending complete request log: #{e.message}"
      end

      def parse_json(string)
        JSON.parse(string)
      rescue JSON::ParserError, TypeError
        string
      end
    end
  end
end
