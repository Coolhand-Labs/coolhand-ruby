# frozen_string_literal: true

require_relative "api_service"

module Coolhand
  module Ruby
    class LoggerService < ApiService
      def initialize
        super("v2/llm_request_logs")
      end

      def log_to_api(captured_data)
        create_log(captured_data)
      end
    end
  end
end
