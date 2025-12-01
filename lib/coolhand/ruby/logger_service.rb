# frozen_string_literal: true

require_relative "api_service"

module Coolhand
  module Ruby
    class LoggerService < ApiService
      def initialize
        super("v2/llm_request_logs")
      end

      def log_to_api(captured_data)
        create_log(captured_data, "auto-monitor")
      end

      # Helper method for forwarding webhook data to Coolhand
      def forward_webhook(webhook_body:, source:, event_type: nil, headers: {}, **options)
        # Validate required parameters
        if webhook_body.nil? || webhook_body.empty?
          error_msg = "webhook_body is required and cannot be nil or empty"
          if Coolhand.configuration.silent
            puts "COOLHAND WARNING: #{error_msg}"
            return false
          else
            raise ArgumentError, error_msg
          end
        end

        if source.nil? || source.to_s.strip.empty?
          error_msg = "source is required and cannot be nil or empty"
          if Coolhand.configuration.silent
            puts "COOLHAND WARNING: #{error_msg}"
            return false
          else
            raise ArgumentError, error_msg
          end
        end

        # Auto-generate required fields unless provided
        webhook_data = {
          id: options[:id] || SecureRandom.uuid,
          timestamp: options[:timestamp] || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
          method: options[:method] || "POST",
          url: options[:url] || build_webhook_url(source, event_type),
          headers: sanitize_headers(headers),
          request_body: clean_webhook_body(webhook_body, source),
          response_body: options[:response_body],
          response_headers: options[:response_headers],
          status_code: options[:status_code] || 200,
          source: "#{source}_webhook"
        }.merge(options.slice(:metadata, :conversation_id, :agent_id))

        # Send to API asynchronously
        log_to_api(webhook_data)
      end

      private

      def build_webhook_url(source, event_type)
        base = "webhook://#{source}"
        event_type ? "#{base}/#{event_type}" : base
      end

      def sanitize_headers(headers)
        return {} if headers.nil? || headers.empty?

        # Handle Rails request headers or plain hash
        clean_headers = {}
        headers.each do |key, value|
          next unless key && value

          # Convert Rails HTTP_ prefix headers
          clean_key = key.to_s.gsub(/^HTTP_/, '').gsub('_', '-').downcase

          # Redact sensitive headers
          clean_value = clean_key.match?(/key|token|secret|authorization/i) ? '[REDACTED]' : value.to_s
          clean_headers[clean_key] = clean_value
        end
        clean_headers
      end

      def clean_webhook_body(body, source)
        # Service-specific binary field filters
        binary_fields = case source.to_s.downcase
        when 'elevenlabs'
          %w[full_audio audio audio_data raw_audio audio_base64 voice_sample audio_url]
        when 'twilio'
          %w[recording_url media_url]
        else
          %w[audio_data image_data file_content binary_content]
        end

        remove_binary_fields(body, binary_fields)
      end

      def remove_binary_fields(obj, fields_to_remove)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), cleaned|
            next if fields_to_remove.any? { |field| key.to_s.downcase.include?(field) }
            cleaned[key] = remove_binary_fields(value, fields_to_remove)
          end
        when Array
          obj.map { |item| remove_binary_fields(item, fields_to_remove) }
        else
          obj
        end
      end
    end
  end
end
