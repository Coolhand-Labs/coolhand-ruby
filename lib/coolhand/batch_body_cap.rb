# frozen_string_literal: true

module Coolhand
  # Applies max_captured_body_bytes to the request/response bodies of batch items, the same way
  # NetHttpInterceptor does for live requests: an oversized body is replaced by the body_too_large
  # marker so the log entry (and the queued job holding it) stays small.
  module BatchBodyCap
    module_function

    # Re-serializing a parsed number can write more bytes than the source had (depending on the json
    # version, "1e9" becomes "1000000000.0" and "7e22" becomes "7.0000000000000004e+22"). Counting
    # the separators around them, a body grows by well under this factor.
    SERIALIZED_GROWTH = 6

    # Returns the body, or the marker when its JSON size is over the cap. `source_size` is the byte
    # size of the JSON the body was parsed from, when the caller has it (e.g. a JSONL line): a body
    # that small even after SERIALIZED_GROWTH is within the cap without serializing it to measure.
    def cap(body, source_size: nil)
      return body if body.nil? || helpers.capture_limit.nil?
      return body if source_size && !helpers.over_capture_limit?(source_size * SERIALIZED_GROWTH)

      size = JSON.generate(body).bytesize
      helpers.over_capture_limit?(size) ? helpers.body_too_large_marker(nil, size) : body
    rescue JSON::NestingError
      helpers.skipped_capture_marker(nil, "nesting_too_deep")
    rescue JSON::JSONError
      # NaN/Infinity or invalid UTF-8: it can't be logged either, and must not fail the other
      # items of the batch.
      helpers.skipped_capture_marker(nil, "unserializable_body")
    end

    def helpers
      NetHttpInterceptor::Helpers
    end
  end
end
