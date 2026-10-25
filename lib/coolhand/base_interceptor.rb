# frozen_string_literal: true

module Coolhand
  # Base module with common functionality for all interceptors
  module BaseInterceptor
    module_function

    # Matches any header whose *name* signals sensitive content, regardless of
    # provider — covers known keys (x-api-key, x-goog-api-key, openai-api-key),
    # AWS SigV4 session tokens (x-amz-security-token), session/CSRF cookies
    # (cookie, set-cookie), and future/unknown providers using a
    # similarly-named header. Shared with LoggerService so the two logging
    # paths (interceptor + webhook forwarding) stay consistent.
    SENSITIVE_HEADER_PATTERN = /key|token|secret|signature|auth|passw|credential|bearer|jwt|session|cookie/i

    # Rate-limit telemetry headers (OpenAI `x-ratelimit-remaining-tokens`, Anthropic
    # `anthropic-ratelimit-input-tokens-reset`, ...) contain the word "token" but carry counts and
    # reset times, not credentials, so redacting them only loses useful data. The vocabulary after
    # `ratelimit` is deliberately closed: a lookalike such as `x-ratelimit-api-key` is not
    # allow-listed and stays redacted. Checked against the downcased header name.
    SAFE_HEADER_PATTERN =
      /\A(?:[a-z0-9]+-){0,2}rate-?limit(?:-(?:limit|remaining|reset|requests|tokens|input|output))+\z/

    # True when a header name should be redacted. Shared with LoggerService so both logging paths
    # make the same call.
    def sensitive_header?(name)
      down = name.to_s.downcase
      down.match?(SENSITIVE_HEADER_PATTERN) && !down.match?(SAFE_HEADER_PATTERN)
    end

    def sanitize_headers(headers)
      return {} if headers.nil?

      # Normalize various header-like objects into a Hash{String => String}
      raw = if headers.is_a?(Hash)
        headers.transform_keys(&:to_s).transform_values { |v| normalize_header_value(v) }
      elsif headers.respond_to?(:to_hash)
        begin
          headers.to_hash.transform_keys(&:to_s).transform_values { |v| normalize_header_value(v) }
        rescue StandardError
          # Deliberately fails closed to an empty hash rather than trying each_header/each on
          # this object next — an object whose own to_hash raises is untrustworthy enough that
          # guessing at another enumeration strategy isn't worth the risk of a second failure.
          nil
        end
      elsif headers.respond_to?(:each_header)
        h = {}
        headers.each_header { |k, v| h[k.to_s] = normalize_header_value(v) }
        h
      elsif headers.respond_to?(:each)
        h = {}
        headers.each { |k, v| h[k.to_s] = normalize_header_value(v) }
        h
      else
        { "raw" => headers.to_s }
      end

      raw ||= {} # in case to_hash raised and nothing was built

      sanitized = raw.dup

      sanitized.each do |k, v|
        next if v.nil?

        key_down = k.to_s.downcase

        if key_down == "authorization"
          sanitized[k] = if v.to_s.match?(/\ABearer\s+/i)
            v.to_s.gsub(/\ABearer\s+.+/i, "Bearer [REDACTED]")
          else
            "[REDACTED]"
          end
        elsif sensitive_header?(key_down)
          sanitized[k] = "[REDACTED]"
        end
      end

      sanitized
    end

    # Helper: convert arrays -> joined string, otherwise to_s
    def normalize_header_value(value)
      if value.is_a?(Array)
        value.join(", ")
      else
        value.to_s
      end
    end

    # Matches query param *names* that signal sensitive content, the same way
    # SENSITIVE_HEADER_PATTERN does for headers — covers exact params this
    # gem already knew about (key/token/secret) as well as presigned-URL
    # credential params used by AWS (X-Amz-Signature, X-Amz-Credential,
    # X-Amz-Security-Token) and Google Cloud (X-Goog-Signature,
    # X-Goog-Credential) storage APIs.
    SENSITIVE_QUERY_PARAM_PATTERN = /key|token|secret|sig|credential|password|auth/i

    # Param names that are sensitive but too short or generic to match as a substring without
    # over-matching (`code` would hit `encoding`, `country_code`). Matched by whole name,
    # case-insensitively: `code` (Azure Functions keys, OAuth authorization codes), `sas` (Azure
    # SAS tokens), and `pwd`/`passwd`, which the `password` substring above does not cover.
    SENSITIVE_QUERY_PARAM_EXACT_NAMES = %w[code sas pwd passwd].freeze

    # Percent-encoded "[REDACTED]", the form the placeholder takes once inside a URL.
    REDACTED_URL_VALUE = "%5BREDACTED%5D"

    # A `;name=value` matrix parameter, in a path segment or smuggled into a query value.
    MATRIX_PARAM_PATTERN = %r{;([^/;?#=&]+)=([^/;?#&]*)}

    def sensitive_query_param?(name)
      decoded = begin
        URI.decode_www_form_component(name)
      rescue ArgumentError
        name
      end
      decoded.match?(SENSITIVE_QUERY_PARAM_PATTERN) || SENSITIVE_QUERY_PARAM_EXACT_NAMES.include?(decoded.downcase)
    end

    def sanitize_url(url)
      uri = URI.parse(url)
      modified = false

      if uri.userinfo
        # URI userinfo syntax disallows "[" / "]", so this can't reuse the [REDACTED]
        # placeholder used elsewhere.
        uri.userinfo = "REDACTED"
        modified = true
      end

      path = uri.path && redact_matrix_params(uri.path)
      if path != uri.path
        uri.path = path
        modified = true
      end

      query = uri.query && redact_query(uri.query)
      if query != uri.query
        uri.query = query
        modified = true
      end

      modified ? uri.to_s : url
    rescue URI::InvalidURIError
      # Fail closed: an unparseable URL can't be checked param-by-param, so drop everything
      # that could carry a credential (userinfo, query, fragment) rather than pass it through.
      url.to_s.sub(%r{//[^/?#]*@}, "//REDACTED@").split(/[?#]/, 2).first
    end

    def redact_matrix_params(text)
      text.gsub(MATRIX_PARAM_PATTERN) do |match|
        sensitive_query_param?(Regexp.last_match(1)) ? ";#{Regexp.last_match(1)}=#{REDACTED_URL_VALUE}" : match
      end
    end

    # Works on the raw query rather than decode_www_form so a bare segment (`?sk-abc123`) is not
    # mistaken for an empty-valued param, and untouched segments pass through byte-for-byte.
    def redact_query(query)
      query.split("&", -1).map { |segment| redact_query_segment(segment) }.join("&")
    end

    def redact_query_segment(segment)
      return segment if segment.empty?

      name, separator, value = segment.partition("=")
      # No "=": nothing says what this is, so a stray token could be a credential. Fail closed.
      return REDACTED_URL_VALUE if separator.empty?
      return "#{name}=#{REDACTED_URL_VALUE}" if sensitive_query_param?(name)

      "#{name}=#{redact_matrix_params(value)}"
    end

    # Key names inside an Azure OpenAI "On Your Data" data_sources/dataSources entry that carry
    # live datastore credentials in the request body, where header/query-param sanitization never
    # looks. Matched against a separator-stripped, lowercased key name so both `connection_string`
    # and `connectionString` (Cosmos/Mongo, embeds `AccountKey=...`) and `encoded_api_key`
    # (Elasticsearch) are caught — not just exact or snake_case-only names.
    SENSITIVE_BODY_KEY_PATTERN = /key|token|secret|passw|pwd|credential|bearer|jwt|connectionstring|signature/i

    def sanitize_body(body)
      return body unless body.is_a?(Hash)

      sanitized = body.dup
      sanitized.each_key do |key|
        next unless key.to_s.delete("_-").casecmp?("datasources")

        sanitized[key] = redact_sensitive_body_values(sanitized[key])
      end
      sanitized
    end

    def redact_sensitive_body_values(node)
      case node
      when Hash
        node.each_with_object({}) do |(k, v), acc|
          normalized = k.to_s.gsub(/[_\-\s]/, "").downcase
          acc[k] = normalized.match?(SENSITIVE_BODY_KEY_PATTERN) ? "[REDACTED]" : redact_sensitive_body_values(v)
        end
      when Array
        node.map { |v| redact_sensitive_body_values(v) }
      when String
        redact_embedded_url_credentials(node)
      else
        node
      end
    end

    # A single whitespace-free absolute URL, e.g. an Azure `endpoint` of `https://u:PASS@h/?sas=...`.
    # Only applied to data_sources config (never prompt content), where a URL value is a datastore
    # address that can carry userinfo or a SAS/key query param in the string itself.
    EMBEDDED_URL_PATTERN = %r{\A[a-z][a-z0-9+.-]*://\S+\z}i

    def redact_embedded_url_credentials(value)
      value.match?(EMBEDDED_URL_PATTERN) ? sanitize_url(value) : value
    end

    def send_complete_request_log(request_id:, method:, url:, request_headers:, request_body:, response_headers:,
      response_body:, status_code:, start_time:, end_time:, duration_ms:, is_streaming:, source_api: nil, model: nil,
      declared: nil)
      raw_request = {
        id: request_id,
        timestamp: start_time.iso8601,
        method: method.to_s.downcase,
        url: sanitize_url(url),
        headers: sanitize_headers(request_headers),
        request_body: sanitize_body(request_body),
        response_headers: sanitize_headers(response_headers),
        response_body: response_body,
        status_code: status_code,
        duration_ms: duration_ms,
        completed_at: end_time.iso8601,
        is_streaming: is_streaming
      }
      raw_request[:source_api] = source_api if Coolhand.required_field?(source_api)
      raw_request[:model] = model if Coolhand.required_field?(model)

      request_data = { raw_request: raw_request }
      request_data[:declared] = declared if declared && !declared.empty?

      LogQueue.submit do
        Coolhand::ApiService.new.send_llm_request_log(request_data)
        Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
      end
    rescue StandardError => e
      Coolhand.log "❌ Error sending complete request log: #{e.message}"
    end

    def parse_json(string)
      JSON.parse(string)
    rescue JSON::ParserError, TypeError
      string
    end
  end
end
