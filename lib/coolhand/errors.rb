# frozen_string_literal: true

module Coolhand
  class Error < StandardError; end

  # Raised by the gem's raising API methods (template reads, feedback links) when the Coolhand API
  # answers with a non-2xx status.
  #
  # `status` is carried so callers can branch on it (404 vs retryable 504) without matching the
  # message text. The exception message is sanitized for printing, but `body` is the raw (length-capped)
  # response body for callers that parse it, so treat it as untrusted before logging it.
  class HttpError < Error
    attr_reader :status, :body

    def initialize(message, status:, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end
end
