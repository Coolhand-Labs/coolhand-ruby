# frozen_string_literal: true

require_relative "base_interceptor"

module Coolhand
  class FaradayInterceptor < Faraday::Middleware
      include BaseInterceptor

      ORIGINAL_METHOD_ALIAS = :coolhand_original_initialize

      def self.patch!
        return if @patched

        @patched = true
        Coolhand.log "📡 Monitoring outbound requests ..."

        # Use prepend instead of alias_method to avoid conflicts with other gems
        Faraday::Connection.prepend(Module.new do
          def initialize(url = nil, options = nil, &block)
            super

            # Only add interceptor if it's not already present
            unless @builder.handlers.any? { |h| h.klass == Coolhand::Ruby::FaradayInterceptor }
              use Coolhand::Ruby::FaradayInterceptor
            end
          end
        end)

        Coolhand.log "🔧 Setting up monitoring for Faraday ..."
      end

      def self.unpatch!
        # NOTE: With prepend, there's no clean way to unpatch
        # We'll mark it as unpatched so it can be re-patched
        @patched = false
        Coolhand.log "🔌 Faraday monitoring disabled ..."
      end

      def self.patched?
        @patched
      end

      def call(env)
        # Skip if Faraday interception is temporarily disabled for this thread
        return super if Thread.current[:coolhand_disable_faraday]

        return super unless llm_api_request?(env)

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
          request_headers: sanitize_headers(env.request_headers),
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
          call_data[:response_headers] = sanitize_headers(response_env.response_headers)
          call_data[:status_code] = response_env.status

          end_time = Time.now
          duration_ms = ((end_time - call_data[:timestamp].to_time) * 1000).round(2)

          # Send complete request/response data in single API call
          Thread.new do
            send_complete_request_log(
              request_id: call_data[:id],
              method: call_data[:method],
              url: call_data[:url],
              request_headers: call_data[:request_headers],
              request_body: call_data[:request_body],
              response_headers: call_data[:response_headers],
              response_body: call_data[:response_body],
              status_code: call_data[:status_code],
              start_time: call_data[:timestamp],
              end_time: end_time,
              duration_ms: duration_ms,
              is_streaming: false
            )
          end
        end
      end
  end
end
