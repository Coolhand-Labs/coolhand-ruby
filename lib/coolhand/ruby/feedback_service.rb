# frozen_string_literal: true

require_relative "api_service"

module Coolhand
  module Ruby
    class FeedbackService < ApiService
      def initialize
        super("v2/llm_request_log_feedbacks")
      end

      def create_feedback(feedback)
        super(feedback, "manual")
      end
    end
  end
end
