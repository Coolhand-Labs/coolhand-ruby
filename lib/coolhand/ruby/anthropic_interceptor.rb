# frozen_string_literal: true

require "anthropic"
require "securerandom"
require "json"
require "ostruct"

module Coolhand
  module Ruby
    module AnthropicInterceptor
      extend self

      def patch!
        return if @patched

        # Patch the BaseClient request method
        require "anthropic/internal/transport/base_client"
        ::Anthropic::Internal::Transport::BaseClient.prepend(RequestInterceptor)

        # Patch MessageStream to capture completion data
        patch_message_stream!

        @patched = true
        Coolhand.log "✅ Anthropic interceptor patched"
      end

      def unpatch!
        # Note: Ruby doesn't have a clean way to unpatch prepended modules
        # This is mainly for testing - in production, patching is permanent
        @patched = false
        Coolhand.log "⚠️  Anthropic interceptor unpatch requested (not fully implemented)"
      end

      def patched?
        @patched ||= false
      end

      def patch_message_stream!
        return unless defined?(Anthropic::Streaming::MessageStream)

        # Load MessageStream class
        require "anthropic/helpers/streaming/message_stream"

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

          # Extract request metadata
          full_url = "#{@base_url}#{path}"

          # Capture all request headers including those added by the client
          request_headers = build_complete_request_headers(headers.dup)
          request_body = body

          # Detect if this is a streaming request
          is_streaming = detect_streaming_request(body, headers)

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
              response_data = extract_response_data(response)

              # Send complete request/response data in single API call
              send_complete_request_log(
                request_id: request_id,
                method: method,
                url: full_url,
                request_headers: request_headers,
                request_body: request_body,
                response_headers: extract_response_headers(response),
                response_body: response_data,
                start_time: start_time,
                end_time: end_time,
                duration_ms: duration_ms,
                is_streaming: is_streaming
              )
            end

            response
          rescue => e
            end_time = Time.now
            duration_ms = ((end_time - start_time) * 1000).round(2)

            # Send error response in single API call
            send_complete_request_log(
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
              start_time: start_time,
              end_time: end_time,
              duration_ms: duration_ms,
              is_streaming: is_streaming
            )
            raise
          end
        end

        private

        def detect_streaming_request(body, headers)
          # Check if stream parameter is set in request body
          return true if body.is_a?(Hash) && body[:stream] == true

          # Check Accept header for Server-Sent Events
          accept_header = headers['Accept'] || headers['accept']
          return true if accept_header&.include?('text/event-stream')

          false
        end

        def send_complete_request_log(request_id:, method:, url:, request_headers:, request_body:, response_headers:, response_body:, start_time:, end_time:, duration_ms:, is_streaming:)
          request_data = {
            raw_request: {
              id: request_id,
              timestamp: start_time.iso8601,
              method: method.to_s.downcase,
              url: url,
              request_headers: request_headers,
              request_body: request_body,
              response_headers: response_headers,
              response_body: response_body,
              duration_ms: duration_ms,
              completed_at: end_time.iso8601,
              is_streaming: is_streaming
            }
          }

          api_service = Coolhand::Ruby::ApiService.new
          api_service.send_llm_request_log(request_data)

          Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
        rescue => e
          Coolhand.log "❌ Error sending complete request log: #{e.message}"
        end

        def extract_response_data(response)
          case response
          when Hash
            response
          when OpenStruct, Struct
            response.to_h
          else
            # Handle streaming responses - these are often enumerator objects
            # that can't be serialized directly
            if response.class.name.include?('Stream') || response.respond_to?(:each)
              {
                response_type: "streaming",
                class: response.class.name,
                note: "Streaming response - content captured during enumeration"
              }
            elsif response.respond_to?(:to_h)
              begin
                response.to_h
              rescue => e
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
              if response.respond_to?(:content)
                response_data[:content] = response.content
              end

              # Extract token usage information
              if response.respond_to?(:usage)
                response_data[:usage] = extract_usage_metadata(response.usage)
              end

              # Extract model information
              if response.respond_to?(:model)
                response_data[:model] = response.model
              end

              # Extract role information
              if response.respond_to?(:role)
                response_data[:role] = response.role
              end

              # Extract ID if available
              if response.respond_to?(:id)
                response_data[:id] = response.id
              end

              # Extract stop reason if available
              if response.respond_to?(:stop_reason)
                response_data[:stop_reason] = response.stop_reason
              end

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

        def extract_response_headers(response)
          # Try to extract headers if the response object exposes them
          if response.respond_to?(:headers)
            clean_response_headers(response.headers)
          elsif response.respond_to?(:response_headers)
            clean_response_headers(response.response_headers)
          else
            # Anthropic gem doesn't expose response headers directly
            # Return empty hash to indicate no headers are available
            {}
          end
        end

        def clean_response_headers(headers)
          cleaned = headers.dup
          # Response headers typically don't contain sensitive data
          # but we can filter if needed
          cleaned
        end

        def build_complete_request_headers(headers)
          # Only clean sensitive data from actual headers, don't add synthetic ones
          clean_headers(headers.dup)
        end

        def clean_headers(headers)
          cleaned = headers.dup

          # Remove sensitive headers
          cleaned.delete('Authorization')
          cleaned.delete('authorization')
          cleaned.delete('x-api-key')
          cleaned.delete('X-API-Key')

          cleaned
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
          rescue => e
            Coolhand.log "❌ Error logging streaming completion: #{e.message}"
          end
        end

        def self.send_complete_request_log(request_id:, method:, url:, request_headers:, request_body:, response_headers:, response_body:, start_time:, end_time:, duration_ms:, is_streaming:)
          request_data = {
            raw_request: {
              id: request_id,
              timestamp: start_time.iso8601,
              method: method.to_s.downcase,
              url: url,
              request_headers: request_headers,
              request_body: request_body,
              response_headers: response_headers,
              response_body: response_body,
              duration_ms: duration_ms,
              completed_at: end_time.iso8601,
              is_streaming: is_streaming
            }
          }

          api_service = Coolhand::Ruby::ApiService.new
          api_service.send_llm_request_log(request_data)

          Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
        rescue => e
          Coolhand.log "❌ Error sending complete request log: #{e.message}"
        end
      end

      module MessageStreamInterceptor
        def accumulated_message
          # Call the original method to get the accumulated message
          message = super

          # Log the completion data if we have streaming request metadata
          streaming_request = Thread.current[:coolhand_streaming_request]
          if streaming_request
            log_streaming_completion(message, streaming_request)
          end

          message
        end

        private

        def log_streaming_completion(message, streaming_request)
          # Convert message to hash for logging (preserving natural format)
          response_body = extract_response_data(message)

          # Send the completion log
          RequestInterceptor.send_complete_request_log(
            request_id: streaming_request[:request_id],
            method: streaming_request[:method],
            url: streaming_request[:url],
            request_headers: streaming_request[:request_headers],
            request_body: streaming_request[:request_body],
            response_headers: {},
            response_body: response_body,
            start_time: streaming_request[:start_time],
            end_time: streaming_request[:end_time],
            duration_ms: streaming_request[:duration_ms],
            is_streaming: streaming_request[:is_streaming]
          )

          # Clear the thread-local data
          Thread.current[:coolhand_streaming_request] = nil
        end

        def extract_response_data(message)
          # Use the same extraction logic as the RequestInterceptor
          case message
          when Hash
            message
          when OpenStruct, Struct
            message.to_h
          else
            # Try to extract the message data
            response_data = {}

            # Get content
            if message.respond_to?(:content)
              response_data[:content] = message.content
            end

            # Extract token usage information
            if message.respond_to?(:usage)
              response_data[:usage] = extract_usage_metadata(message.usage)
            end

            # Extract model information
            if message.respond_to?(:model)
              response_data[:model] = message.model
            end

            # Extract role information
            if message.respond_to?(:role)
              response_data[:role] = message.role
            end

            # Extract ID if available
            if message.respond_to?(:id)
              response_data[:id] = message.id
            end

            # Extract stop reason if available
            if message.respond_to?(:stop_reason)
              response_data[:stop_reason] = message.stop_reason
            end

            # Add class info for debugging
            response_data[:class] = message.class.name

            response_data.empty? ? { raw_response: message.to_s, class: message.class.name } : response_data
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
      end
    end
  end
end