# frozen_string_literal: true

module Coolhand
  class Interceptor < Faraday::Middleware
    ORIGINAL_METHOD_ALIAS = :coolhand_original_initialize

    def self.patch!
      return if Faraday::Connection.private_method_defined?(ORIGINAL_METHOD_ALIAS)

      Coolhand.log "📡 Monitoring outbound requests ..."

      Faraday::Connection.class_eval do
        alias_method ORIGINAL_METHOD_ALIAS, :initialize

        def initialize(url = nil, options = nil, &block)
          send(ORIGINAL_METHOD_ALIAS, url, options, &block)

          use Interceptor
        end
      end

      Coolhand.log "🔧 Setting up monitoring for Faraday ..."
    end

    def self.unpatch!
      return unless Faraday::Connection.private_method_defined?(ORIGINAL_METHOD_ALIAS)

      Faraday::Connection.class_eval do
        alias_method :initialize, ORIGINAL_METHOD_ALIAS
        remove_method ORIGINAL_METHOD_ALIAS
      end

      Coolhand.log "🔌 Faraday unpatched ..."
    end

    def call(env)
      return super(env) unless llm_api_request?(env)

      Coolhand.log "🎯 INTERCEPTING OpenAI call #{env.url}"

      call_data = build_call_data(env)
      buffer = override_on_data(env)

      process_complete_callback(env, buffer, call_data)
    end

    private

    def llm_api_request?(env)
      Coolhand.configuration.intercept_addresses.any? do |address|
        env.url.to_s.include?(address)
      end
    end

    def build_call_data(env)
      {
        id: SecureRandom.uuid,
        timestamp: DateTime.now,
        method: env.method,
        url: env.url.to_s,
        headers: sanitize_headers(env.request_headers),
        request_body: parse_json(env.request_body),
        response_body: nil,
        response_headers: nil,
        status_code: nil
      }
    end

    def override_on_data(env)
      buffer = +""
      original_on_data = env.request.on_data
      env.request.on_data = proc do |chunk, overall_received_bytes|
        buffer << chunk

        original_on_data&.call(chunk, overall_received_bytes)
      end

      buffer
    end

    def process_complete_callback(env, buffer, call_data)
      @app.call(env).on_complete do |response_env|
        if buffer.empty?
          body = response_env.body
        else
          body = buffer
          response_env.body = body
        end

        call_data[:response_body] = parse_json(body)
        call_data[:response_headers] = sanitize_headers(response_env.request_headers)
        call_data[:status_code] = response_env.status

        Thread.new { Coolhand.logger_service.log_to_api(call_data) }
      end
    end

    def parse_json(string)
      JSON.parse(string)
    rescue JSON::ParserError, TypeError
      string
    end

    def sanitize_headers(headers)
      sanitized = headers.transform_keys(&:to_s).dup

      if sanitized["Authorization"]
        sanitized["Authorization"] = sanitized["Authorization"].gsub(/Bearer .+/, "Bearer [REDACTED]")
      end

      %w[openai-api-key api-key].each do |key|
        sanitized[key] = "[REDACTED]" if sanitized[key]
      end

      sanitized
    end
  end
end
