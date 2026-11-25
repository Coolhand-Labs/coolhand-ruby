# frozen_string_literal: true

require_relative "api_service"
require_relative "log_queue"

module Coolhand
  class FeedbackService < ApiService
    # How long feedback addressed by `client_unique_id` waits for its own log to finish sending.
    LOG_WAIT_TIMEOUT = LogQueue::DEFAULT_FLUSH_TIMEOUT

    def initialize
      super("v2/llm_request_log_feedbacks")
    end

    # Feedback carrying a `client_unique_id` whose log is still queued in this process is held until
    # that log's send completes, so it can't arrive first. If that send failed, Coolhand never got the
    # log and the feedback has nothing to attach to, so it is not sent (returns nil).
    def create_feedback(feedback)
      return nil unless log_delivered?(feedback[:client_unique_id])

      super(feedback, "manual")
    end

    private

    def log_delivered?(client_unique_id)
      return true unless client_unique_id

      case LogQueue.await_delivery(client_unique_id, timeout: LOG_WAIT_TIMEOUT)
      when :failed
        log "⚠️ Not sending feedback: the log for client_unique_id #{client_unique_id.inspect} failed to send"
        false
      when :timeout
        log "⚠️ Sending feedback for client_unique_id #{client_unique_id.inspect} before its log finished " \
            "sending (waited #{LOG_WAIT_TIMEOUT}s)"
        true
      else
        true
      end
    end
  end
end
