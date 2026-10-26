# frozen_string_literal: true

module Coolhand
  # Applies max_captured_body_bytes to the request/response bodies of batch items, the same way
  # NetHttpInterceptor does for live requests: an oversized body is replaced by the body_too_large
  # marker so the log entry (and the queued job holding it) stays small.
  module BatchBodyCap
    module_function

    # Returns the body, or the marker when its JSON size is over the cap. `max_size` is an upper
    # bound on the body's size when the caller has one (e.g. the byte length of the JSONL line the
    # body was parsed from); a bound within the cap lets us skip serializing the body to measure it.
    def cap(body, max_size: nil)
      return body if body.nil? || (max_size && !helpers.over_capture_limit?(max_size))
      return body if helpers.capture_limit.nil?

      size = JSON.generate(body).bytesize
      helpers.over_capture_limit?(size) ? helpers.body_too_large_marker(nil, size) : body
    end

    def helpers
      NetHttpInterceptor::Helpers
    end
  end
end
