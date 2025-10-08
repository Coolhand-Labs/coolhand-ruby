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

      Coolhand.log "🔧 Setting up Coolhand monitoring for Faraday ..."
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
      Coolhand.log "🎯 INTERCEPTING OpenAI call #{env.url}"

      buffer = +""
      original_on_data = env.request.on_data
      env.request.on_data = proc do |chunk, overall_received_bytes|
        buffer << chunk

        original_on_data&.call(chunk, overall_received_bytes)
      end

      @app.call(env).on_complete do |response_env|
        if buffer.empty?
          body = response_env.body
        else
          body = buffer
          response_env.body = body
        end

        Thread.new { Logger.log_to_api(body) }
      end
    end
  end
end
