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

    # Returns the parsed response. A failure returns nil (and logs, unless `config.silent`); pass
    # `raise_on_error: true` to get {Coolhand::HttpError} (non-2xx) or {Coolhand::Error} (no API
    # key, network error, or the log for `client_unique_id` failed to send) instead. In debug mode
    # nothing is sent and the result is nil. See docs/feedback.md.
    #
    # The fields may be passed as a Hash or as bare keywords (`create_feedback(client_unique_id: "x")`).
    #
    # Feedback carrying a `client_unique_id` whose log is still queued in this process is held until
    # that log's send completes, so it can't arrive first. If that send failed, Coolhand never got the
    # log and the feedback has nothing to attach to, so it is not sent.
    def create_feedback(feedback = nil, raise_on_error: false, **fields)
      # A Hash plus stray keywords is almost certainly a misspelled option, which would otherwise be
      # merged into the payload and silently not raise.
      raise ArgumentError, "unknown keywords: #{fields.keys.join(', ')}" if feedback && fields.any?

      payload = (feedback || {}).merge(fields)
      return log_failed(payload[:client_unique_id], raise_on_error) unless log_delivered?(payload[:client_unique_id])

      super(payload, "manual", raise_on_error: raise_on_error)
    end

    private

    # Feedback for a log that failed to send is not posted: returns nil, or raises when asked to.
    def log_failed(client_unique_id, raise_on_error)
      message = "Not sending feedback: the log for client_unique_id #{client_unique_id.inspect} failed to send"
      raise Error, message if raise_on_error

      log "⚠️ #{message}"
      nil
    end

    def log_delivered?(client_unique_id)
      return true unless client_unique_id

      case LogQueue.await_delivery(client_unique_id, timeout: LOG_WAIT_TIMEOUT)
      when :failed
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
