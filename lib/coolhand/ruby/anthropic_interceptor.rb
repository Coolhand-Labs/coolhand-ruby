# frozen_string_literal: true

begin
  require "anthropic"
rescue LoadError
  # Anthropic gem not available - interceptor will be a no-op
end
require "securerandom"
require "json"
require "ostruct"
require_relative "base_interceptor"

module Coolhand
  module Ruby
    module AnthropicInterceptor
      module_function

      def patch!
        return if @patched
        return unless defined?(Anthropic)

        # Check if both anthropic gems are installed
        if both_gems_installed?
          # Always show this warning, regardless of silent mode
          warn_message = "⚠️  Warning: Both 'anthropic' and 'ruby-anthropic' gems are installed. " \
                         "Coolhand will only monitor ruby-anthropic (Faraday-based) requests. " \
                         "Official anthropic gem monitoring has been disabled."
          puts "COOLHAND: #{warn_message}"

          # Mark as patched since ruby-anthropic will be handled by FaradayInterceptor
          @patched = true
          return
        end

        # Check if we're using the official anthropic gem
        # The official gem has Anthropic::Internal, ruby-anthropic doesn't
        if defined?(Anthropic::Internal)
          # Patch the BaseClient request method for official anthropic gem
          require "anthropic/internal/transport/base_client"
          ::Anthropic::Internal::Transport::BaseClient.prepend(RequestInterceptor)
        else
          # ruby-anthropic uses Faraday, so the FaradayInterceptor already handles it
          Coolhand.log "✅ ruby-anthropic detected, using Faraday interceptor"
          @patched = true
          return
        end

        # Patch MessageStream to capture completion data
        patch_message_stream!

        @patched = true
        Coolhand.log "✅ Anthropic interceptor patched"
      end

      def unpatch!
        # NOTE: Ruby doesn't have a clean way to unpatch prepended modules
        # This is mainly for testing - in production, patching is permanent
        @patched = false
        Coolhand.log "⚠️  Anthropic interceptor unpatch requested (not fully implemented)"
      end

      def patched?
        @patched ||= false
      end

      def both_gems_installed?
        # Check if both gems are installed by looking at loaded specs
        anthropic_gem = Gem.loaded_specs["anthropic"]
        ruby_anthropic_gem = Gem.loaded_specs["ruby-anthropic"]

        anthropic_gem && ruby_anthropic_gem
      end

      def patch_message_stream!
        # Try to load MessageStream class if available
        begin
          require "anthropic/helpers/streaming/message_stream"
        rescue LoadError
          # MessageStream not available in this version of anthropic gem
          return
        end

        # Only proceed if the constant is now defined
        return unless defined?(Anthropic::Streaming::MessageStream)

        # Prepend our patch module
        ::Anthropic::Streaming::MessageStream.prepend(MessageStreamInterceptor)
      end

      module RequestInterceptor
        def request(method:, path:, body: nil, headers: {}, **options)
          # Generate request ID for correlation
          request_id = SecureRandom.hex(16)
          start_time = Time.now

          # Store request ID in thread-local storage for application access
          Thread.current[:coolhand_current_request_id] = request_id

          # Temporarily disable Faraday interception for this thread to prevent double logging
          Thread.current[:coolhand_disable_faraday] = true

          # Extract request metadata
          full_url = "#{@base_url}#{path}"

          # Capture all request headers including those added by the client
          request_headers = BaseInterceptor.clean_request_headers(headers.dup)
          request_body = body

          # Detect if this is a streaming request
          is_streaming = streaming_request?(body, headers)

          # Call the original request method
          begin
            response = super
            end_time = Time.now
            duration_ms = ((end_time - start_time) * 1000).round(2)

            # For streaming responses, store request metadata for later logging
            if is_streaming
              Thread.current[:coolhand_streaming_request] = {
                request_id: request_id,
                method: method,
                url: full_url,
                request_headers: request_headers,
                request_body: request_body,
                start_time: start_time,
                end_time: end_time,
                duration_ms: duration_ms,
                is_streaming: is_streaming
              }
            else
              # Extract response data
              response_data = BaseInterceptor.extract_response_data(response)

              # Send complete request/response data in single API call
              BaseInterceptor.send_complete_request_log(
                request_id: request_id,
                method: method,
                url: full_url,
                request_headers: request_headers,
                request_body: request_body,
                response_headers: extract_response_headers(response),
                response_body: response_data,
                status_code: nil,
                start_time: start_time,
                end_time: end_time,
                duration_ms: duration_ms,
                is_streaming: is_streaming
              )
            end

            response
          rescue StandardError => e
            end_time = Time.now
            duration_ms = ((end_time - start_time) * 1000).round(2)

            # Send error response in single API call
            BaseInterceptor.send_complete_request_log(
              request_id: request_id,
              method: method,
              url: full_url,
              request_headers: request_headers,
              request_body: request_body,
              response_headers: {},
              response_body: {
                error: {
                  message: e.message,
                  class: e.class.name
                }
              },
              status_code: nil,
              start_time: start_time,
              end_time: end_time,
              duration_ms: duration_ms,
              is_streaming: is_streaming
            )
            raise
          ensure
            # Always re-enable Faraday interception for this thread
            Thread.current[:coolhand_disable_faraday] = false
          end
        end

        # Public method for applications to log final streaming response
        def self.log_streaming_completion(final_response_body)
          streaming_request = Thread.current[:coolhand_streaming_request]
          return unless streaming_request

          begin
            send_complete_request_log(
              request_id: streaming_request[:request_id],
              method: streaming_request[:method],
              url: streaming_request[:url],
              request_headers: streaming_request[:request_headers],
              request_body: streaming_request[:request_body],
              response_headers: {},
              response_body: final_response_body,
              start_time: streaming_request[:start_time],
              end_time: streaming_request[:end_time],
              duration_ms: streaming_request[:duration_ms],
              is_streaming: streaming_request[:is_streaming]
            )

            # Clear the thread-local data
            Thread.current[:coolhand_streaming_request] = nil
          rescue StandardError => e
            Coolhand.log "❌ Error logging streaming completion: #{e.message}"
          end
        end

        def self.send_complete_request_log(request_id:, method:, url:, request_headers:, request_body:,
          response_headers:, response_body:, start_time:, end_time:, duration_ms:, is_streaming:)
          BaseInterceptor.send_complete_request_log(
            request_id: request_id,
            method: method,
            url: url,
            request_headers: request_headers,
            request_body: request_body,
            response_headers: response_headers,
            response_body: response_body,
            status_code: nil,
            start_time: start_time,
            end_time: end_time,
            duration_ms: duration_ms,
            is_streaming: is_streaming
          )
        end

        private

        def streaming_request?(body, headers)
          # Check if stream parameter is set in request body
          return true if body.is_a?(Hash) && body[:stream] == true

          # Check Accept header for Server-Sent Events
          accept_header = headers["Accept"] || headers["accept"]
          return true if accept_header&.include?("text/event-stream")

          false
        end

        def extract_response_headers(response)
          # Try to extract headers if the response object exposes them
          if response.respond_to?(:headers)
            BaseInterceptor.clean_response_headers(response.headers)
          elsif response.respond_to?(:response_headers)
            BaseInterceptor.clean_response_headers(response.response_headers)
          else
            # Anthropic gem doesn't expose response headers directly
            # Return empty hash to indicate no headers are available
            {}
          end
        end
      end

      module MessageStreamInterceptor
        def accumulated_message
          # Call the original method to get the accumulated message
          message = super

          # Log the completion data if we have streaming request metadata
          streaming_request = Thread.current[:coolhand_streaming_request]
          log_streaming_completion(message, streaming_request) if streaming_request

          message
        end

        private

        def log_streaming_completion(message, streaming_request)
          # Convert message to hash for logging (preserving natural format)
          response_body = extract_response_data(message)

          # Send the completion log
          BaseInterceptor.send_complete_request_log(
            request_id: streaming_request[:request_id],
            method: streaming_request[:method],
            url: streaming_request[:url],
            request_headers: streaming_request[:request_headers],
            request_body: streaming_request[:request_body],
            response_headers: {},
            response_body: response_body,
            status_code: nil,
            start_time: streaming_request[:start_time],
            end_time: streaming_request[:end_time],
            duration_ms: streaming_request[:duration_ms],
            is_streaming: streaming_request[:is_streaming]
          )

          # Clear the thread-local data
          Thread.current[:coolhand_streaming_request] = nil
        end

        def extract_response_data(message)
          BaseInterceptor.extract_response_data(message)
        end
      end
    end
  end
end
