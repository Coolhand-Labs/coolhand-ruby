# frozen_string_literal: true

module Coolhand
  # Redacts credentials in raw String bodies, which BodyRedactor's tree walk never sees: a streamed
  # (server-sent event) response arrives as one String of `data: {...}` lines, and a webhook body
  # may be raw JSON text. Each JSON object/array payload is parsed, run through BodyRedactor and
  # re-serialized; text that is not JSON (plain text, `[DONE]`, `event:` and comment lines, a
  # payload that fails to parse) is left byte for byte. A payload is only rewritten when redaction
  # actually changed it, so an untouched stream keeps its exact formatting.
  module StringBodyRedactor
    module_function

    NESTING_MARKER = { "_coolhand_capture_skipped" => "nesting_too_deep" }.freeze

    # A `data:` field at the start of a line (LF, CRLF or bare CR). One space after the colon
    # belongs to the SSE field syntax, so it is captured apart from the payload.
    DATA_LINE = /(?<![^\r\n])data:( ?)([^\r\n]*)/
    JSON_CONTAINER = /\A\s*[\[{]/

    def redact(body)
      text = utf8_text(body)
      text.match?(JSON_CONTAINER) ? (redacted_json(text) || body) : redact_stream(body, text)
    rescue StandardError => e
      # Fail closed: never log a body that could not be checked. The message is left out because
      # a parser error can quote the payload.
      Coolhand.log "❌ Error redacting string body: #{e.class}"
      { "_coolhand_capture_skipped" => "redaction_failed" }
    end

    # Streamed bodies are captured as UTF-8, but a binary-tagged or invalid-UTF-8 String is not
    # worth a failure: scrub a working copy so every line can still be inspected.
    def utf8_text(body)
      text = body.encoding == Encoding::UTF_8 ? body : body.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub
    end

    # One pass with gsub (linear in the body); the original String is returned when no line changed.
    def redact_stream(body, text)
      changed = false
      redacted = text.gsub(DATA_LINE) do |line|
        match = Regexp.last_match
        payload = match[2].match?(JSON_CONTAINER) ? redacted_json(match[2]) : nil
        next line unless payload

        changed = true
        "data:#{match[1]}#{payload}"
      end
      changed ? redacted : body
    end

    # The re-serialized JSON when redaction changed it; nil when the text should stay as is
    # (not a JSON object/array, unparsable, or nothing to redact).
    def redacted_json(text)
      parsed = JSON.parse(text)
      return unless parsed.is_a?(Hash) || parsed.is_a?(Array)

      redacted = BodyRedactor.redact(parsed)
      JSON.generate(redacted) unless redacted == parsed
    rescue JSON::NestingError
      JSON.generate(NESTING_MARKER)
    rescue JSON::ParserError
      nil
    end
  end
end
