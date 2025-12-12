# frozen_string_literal: true

require_relative "api_service"

module Coolhand
  module Ruby
    class LlmResponsesService < ApiService
      def initialize
        super("v2/llm_responses")
      end

      def log_streaming_response(response_data)
        payload = {
          llm_response: {
            raw_response: response_data,
            collector: Collector.get_collector_string
          }
        }

        log "📤 Logging streaming response to LLM endpoint"

        result = send_request(
          payload,
          "✅ Successfully logged streaming response"
        )

        log_separator
        result
      end
    end
  end
end
