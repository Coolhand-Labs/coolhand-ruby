# frozen_string_literal: true

require_relative "api_service"

module Coolhand
  class LoggerService < ApiService
    # CGI/Rack/Rails/app-server variables that show up in a Rails `request.headers` iteration
    # (it walks the whole Rack env) but are not HTTP headers. CONTENT_TYPE and
    # CONTENT_LENGTH are real headers and are deliberately absent. ORIGINAL_FULLPATH and
    # REQUEST_PATH carry the query string, so they must never be forwarded.
    RACK_ENV_CGI_KEYS = %w[
      AUTH_TYPE GATEWAY_INTERFACE HTTPS HTTP_VERSION ORIGINAL_FULLPATH ORIGINAL_SCRIPT_NAME
      PATH_INFO PATH_TRANSLATED QUERY_STRING REMOTE_ADDR REMOTE_HOST REMOTE_IDENT REMOTE_PORT
      REMOTE_USER REQUEST_METHOD REQUEST_PATH REQUEST_URI SCRIPT_NAME SERVER_ADDR SERVER_NAME
      SERVER_PORT SERVER_PROTOCOL SERVER_SOFTWARE
    ].freeze

    # CGI-style env key: uppercase letters, digits and underscores (REQUEST_METHOD, DATABASE_URL).
    CGI_ENV_KEY_PATTERN = /\A[A-Z0-9_]+\z/
    RACK_ENV_HEADER_KEYS = %w[CONTENT_TYPE CONTENT_LENGTH].freeze

    def initialize
      super("v2/llm_request_logs")
    end

    def log_to_api(captured_data)
      create_log(captured_data, "auto-monitor")
    end

    # Helper method for forwarding webhook data to Coolhand
    def forward_webhook(webhook_body:, source:, event_type: nil, headers: {}, **options)
      # Validate required parameters
      { webhook_body: webhook_body, source: source }.each do |name, value|
        return reject_webhook("#{name} is required and cannot be nil or empty") unless Coolhand.required_field?(value)
      end

      # Auto-generate required fields unless provided
      webhook_data = {
        id: options[:id] || SecureRandom.uuid,
        timestamp: options[:timestamp] || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        method: options[:method] || "POST",
        url: BaseInterceptor.sanitize_url(options[:url] || build_webhook_url(source, event_type)),
        headers: sanitize_headers(headers),
        request_body: clean_webhook_body(webhook_body, source),
        response_body: options[:response_body],
        response_headers: options[:response_headers] && sanitize_headers(options[:response_headers]),
        status_code: options[:status_code] || 200,
        source: "#{source}_webhook"
      }.merge(options.slice(:metadata, :conversation_id, :agent_id))

      # Send to API asynchronously
      log_to_api(webhook_data)
    end

    private

    # Silent mode warns and drops the webhook; otherwise the caller gets the error.
    def reject_webhook(error_msg)
      raise ArgumentError, error_msg unless Coolhand.configuration.silent

      puts "COOLHAND WARNING: #{error_msg}"
      false
    end

    def build_webhook_url(source, event_type)
      base = "webhook://#{source}"
      event_type ? "#{base}/#{event_type}" : base
    end

    def sanitize_headers(headers)
      return {} if headers.nil?
      return {} if headers.respond_to?(:empty?) && headers.empty?
      return {} unless headers.respond_to?(:each)

      # Handle Rails request headers or plain hash
      entries = headers.enum_for(:each).to_a
      rack_env = rack_env_shaped?(entries)

      clean_headers = {}
      entries.each do |key, value|
        next unless forwardable_header?(key, value, rack_env: rack_env)

        # Convert Rails HTTP_ prefix headers
        clean_key = key.to_s.gsub(/^HTTP_/, "").tr("_", "-").downcase

        # Redact sensitive headers (shared with BaseInterceptor so both logging
        # paths treat the same header names as sensitive)
        clean_value = BaseInterceptor.sensitive_header?(clean_key) ? "[REDACTED]" : value.to_s
        clean_headers[clean_key] = clean_value
      end
      clean_headers
    end

    # Rails' request.headers#each yields the whole Rack env, not just headers. Drop the
    # non-header entries (rack.session, action_dispatch.*, REQUEST_METHOD, QUERY_STRING, ...)
    # so session/params data is never forwarded. Ordinary header names (including normalized
    # plain-Hash ones like "Content-Type" or "x-webhook-id") never match; only dotted keys do.
    # A whole Rack env (CGI/FastCGI handlers put the process env in it: DATABASE_URL,
    # REDIS_URL, ...) is recognised by its key shape and gets an allowlist instead.
    def forwardable_header?(key, value, rack_env: false)
      return false unless key && value

      name = key.to_s
      return false if name.include?(".") || RACK_ENV_CGI_KEYS.include?(name)

      !rack_env || name.start_with?("HTTP_") || RACK_ENV_HEADER_KEYS.include?(name)
    end

    def rack_env_shaped?(entries)
      keys = entries.filter_map { |key, _value| key&.to_s }
      keys.any? && keys.all? { |name| name.include?(".") || name.match?(CGI_ENV_KEY_PATTERN) }
    end

    def clean_webhook_body(body, source)
      # Service-specific binary field filters
      binary_fields = case source.to_s.downcase
                      when "elevenlabs"
                        %w[full_audio audio audio_data raw_audio audio_base64 voice_sample audio_url]
                      when "twilio"
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
