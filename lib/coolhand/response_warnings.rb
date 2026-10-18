# frozen_string_literal: true

module Coolhand
  # Prints the `warnings` a Coolhand log response carries, for {ApiService}.
  #
  # Warnings come from the response body and are written to the host app's stdout, so they are
  # untrusted: each is coerced to a string, stripped of control characters and length-capped, and
  # the number printed per response is bounded.
  module ResponseWarnings
    MAX_WARNING_LENGTH = 500
    MAX_WARNINGS = 5

    protected

    # The server ingests a log normally but ignores a declared workload/template it cannot honour
    # (e.g. over the public-key cap), and says so here.
    def log_response_warnings(result)
      warnings = result.is_a?(Hash) ? Array(result[:warnings]) : []
      warnings.first(MAX_WARNINGS).each { |warning| log "⚠️ Coolhand: #{sanitize_warning(warning)}" }

      omitted = warnings.size - MAX_WARNINGS
      log "⚠️ Coolhand: ... and #{omitted} more warning(s) omitted" if omitted.positive?
    end

    private

    # Control characters and line/paragraph separators are replaced with a space, not dropped: a
    # newline would forge a log line and ESC starts a terminal escape sequence. Unicode format
    # characters (bidi overrides, zero-width) are invisible and can reorder or hide text in a
    # terminal, so they are removed outright.
    def sanitize_warning(warning)
      text = warning.to_s.dup.force_encoding("UTF-8").scrub
      text = text.gsub(/\p{Cf}+/, "").gsub(/[[:cntrl:]\p{Zl}\p{Zp}]+/, " ").strip
      return text if text.length <= MAX_WARNING_LENGTH

      "#{text[0, MAX_WARNING_LENGTH]}... [truncated]"
    end
  end
end
