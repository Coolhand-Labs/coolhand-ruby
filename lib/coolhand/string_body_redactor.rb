# frozen_string_literal: true

module Coolhand
  # Redacts credentials in raw String bodies, which BodyRedactor's tree walk never sees: a streamed
  # (server-sent event) response arrives as one String of `data: {...}` lines, and a webhook body
  # may be raw JSON text. Each JSON object/array payload is parsed, run through BodyRedactor and
  # re-serialized; text that is not JSON (plain text, `[DONE]`, `event:` and comment lines, a
  # payload that fails to parse) is left byte for byte. A JSON payload is always re-serialized, even
  # when nothing in it needed redacting: JSON.parse keeps only the last of a repeated key, so
  # "nothing changed" cannot be trusted to mean "no credential in the original text".
  module StringBodyRedactor
    module_function

    NESTING_MARKER = { "_coolhand_capture_skipped" => "nesting_too_deep" }.freeze
    FAILED_MARKER = { "_coolhand_capture_skipped" => "redaction_failed" }.freeze

    # A `data:` field at the start of a line (LF, CRLF or bare CR), or after a byte order mark,
    # which the SSE spec ignores. One space after the colon belongs to the SSE field syntax,
    # so it is captured apart from the payload.
    DATA_LINE = /(?<![^\r\n\uFEFF])data:( ?)([^\r\n]*)/
    JSON_CONTAINER = /\A\uFEFF?\s*[\[{]/

    def redact(body)
      text = utf8_text(body)
      text.match?(JSON_CONTAINER) ? (redacted_json(text) || body) : redact_stream(body, text)
    rescue StandardError => e
      # Fail closed: never log a body that could not be checked. The message is left out because
      # a parser error can quote the payload.
      Coolhand.log "❌ Error redacting string body: #{e.class}"
      FAILED_MARKER
    end

    # Captured bodies are UTF-8, but a binary-tagged, other-encoded or invalid-UTF-8 String (a
    # webhook body can be any of them) is not worth a failure: inspect a UTF-8 working copy, with
    # invalid bytes replaced, so every line can still be checked.
    def utf8_text(body)
      text = case body.encoding
             when Encoding::UTF_8 then body
             when Encoding::BINARY then body.dup.force_encoding(Encoding::UTF_8)
             else body.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
      text.valid_encoding? ? text : text.scrub
    end

    # One pass with gsub (linear in the body); the original String is returned when no line differs
    # once re-serialized (providers emit compact JSON, so a clean stream usually round-trips as is).
    def redact_stream(body, text)
      changed = false
      redacted = text.gsub(DATA_LINE) do |line|
        match = Regexp.last_match
        payload = match[2].match?(JSON_CONTAINER) ? redacted_json(match[2]) : nil
        next line if payload.nil? || payload == match[2]

        changed = true
        "data:#{match[1]}#{payload}"
      end
      changed ? redacted : body
    end

    # The redacted, re-serialized JSON; nil when the text should stay as is (not a JSON
    # object/array, or unparsable). Anything else that goes wrong yields a `redaction_failed`
    # marker rather than the unchecked text.
    def redacted_json(text)
      # NaN/Infinity are not JSON, but some servers emit them; a payload that failed to parse
      # would be logged unredacted next to its credential-named fields.
      parsed = JSON.parse(text.delete_prefix("\uFEFF"), allow_nan: true)
      return unless parsed.is_a?(Hash) || parsed.is_a?(Array)

      redacted = BodyRedactor.redact(parsed)
      JSON.generate(redacted, allow_nan: true)
    rescue JSON::NestingError
      JSON.generate(NESTING_MARKER)
    rescue JSON::ParserError
      nil
    rescue StandardError => e
      # e.g. a string with a lone surrogate that parses but cannot be serialized: fail closed for
      # this payload alone so the rest of the body is still redacted.
      Coolhand.log "❌ Error redacting JSON payload: #{e.class}"
      JSON.generate(FAILED_MARKER)
    end
  end
end
