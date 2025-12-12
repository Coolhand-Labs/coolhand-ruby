# frozen_string_literal: true

module Coolhand
  module Ruby
    # Service for manually forwarding streaming API response data to Coolhand
    # This is designed for APIs like Anthropic where streaming responses need to be
    # captured manually after the client has consumed the stream
    class StreamingResponseForwarder
      def initialize(llm_responses_service = nil)
        @llm_responses_service = llm_responses_service || Coolhand.llm_responses_service
      end

      # Forward a streaming API response to Coolhand
      # @param request_data [Hash] The original request data
      # @param response [Object] The API response object or hash
      # @param correlation_id [String] Custom correlation ID (optional)
      # @param response_headers [Hash] HTTP response headers (optional)
      def forward_response(request_data, response, correlation_id: nil, response_headers: nil)
        # Extract correlation ID from response if available
        correlation_id ||= extract_correlation_id(response)

        # Build response data structure as raw_request with response_body and response_headers
        raw_request = build_raw_request(request_data, response, correlation_id, response_headers)

        # Send to Coolhand LLM responses endpoint in background thread
        send_to_coolhand(raw_request, correlation_id)
      end

      private

      def extract_correlation_id(response)
        if response.respond_to?(:id)
          response.id
        elsif response.is_a?(Hash) && (response["id"] || response[:id])
          response["id"] || response[:id]
        else
          "unknown_#{SecureRandom.hex(4)}"
        end
      rescue StandardError
        "unknown_#{SecureRandom.hex(4)}"
      end

      def build_raw_request(_request_data, response, _correlation_id, provided_headers = nil)
        # Extract the response body
        response_body = extract_response_body(response)
        response_headers = provided_headers || {}

        # Structure as raw_request with response_body and response_headers
        {
          response_body: response_body,
          response_headers: response_headers
        }
      end

      def extract_response_body(response)
        if response.nil?
          nil
        elsif response.respond_to?(:to_h) && !response.nil?
          # If it has to_h, use it directly
          response.to_h
        elsif response.respond_to?(:content) && response.respond_to?(:usage)
          # For Anthropic-style response objects, extract the raw structure
          {
            id: response.respond_to?(:id) ? response.id : nil,
            type: response.respond_to?(:type) ? response.type : nil,
            role: response.respond_to?(:role) ? response.role : nil,
            model: response.respond_to?(:model) ? response.model : nil,
            content: response.content.respond_to?(:map) ? response.content.map(&:to_h) : response.content,
            stop_reason: response.respond_to?(:stop_reason) ? response.stop_reason : nil,
            stop_sequence: response.respond_to?(:stop_sequence) ? response.stop_sequence : nil,
            usage: response.usage.respond_to?(:to_h) ? response.usage.to_h : response.usage
          }.compact # Remove nil values
        else
          # Return as-is for hashes, strings, or other types
          response
        end
      end


      def send_to_coolhand(raw_request, correlation_id)
        Thread.new do
          @llm_responses_service.log_streaming_response(raw_request)
          Coolhand.log "✅ Sent streaming response to Coolhand LLM endpoint (correlation_id: #{correlation_id})"
        rescue StandardError => e
          Coolhand.log "❌ Failed to send streaming response to Coolhand: #{e.message}"
        end
      end
    end
  end
end
