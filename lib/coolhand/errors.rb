# frozen_string_literal: true

module Coolhand
  class Error < StandardError; end

  # Raised by the gem's read methods when the Coolhand API answers with a non-2xx status.
  #
  # The write path (`send_llm_request_log`, `create_log`, `create_feedback`) deliberately logs and
  # returns nil: instrumentation must never crash the host app. Reads are the opposite — the caller
  # asked for data and has to be able to react to not getting it, so they raise instead.
  #
  # `status` carries the HTTP status code so callers can branch on it directly rather than matching
  # against the message. That matters most for 504, which is an expected, retryable response on the
  # template endpoints (their `log_count` aggregate is bounded by a server-side statement timeout)
  # rather than a fault to report as a generic server error.
  class HttpError < Error
    attr_reader :status, :body

    def initialize(message, status:, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end
end
