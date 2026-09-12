# frozen_string_literal: true

module Coolhand
  class Error < StandardError; end

  # Raised by the gem's read methods when the Coolhand API answers with a non-2xx status.
  #
  # `status` is carried so callers can branch on it (404 vs retryable 504) without matching the
  # message text.
  class HttpError < Error
    attr_reader :status, :body

    def initialize(message, status:, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end
end
