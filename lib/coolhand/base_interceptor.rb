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
    SENSITIVE_HEADER_PATTERN = /key|token|secret|signature|authorization|cookie/i

    def sanitize_headers(headers)
      return {} if headers.nil?

      # Normalize various header-like objects into a Hash{String => String}
      raw = if headers.is_a?(Hash)
        headers.transform_keys(&:to_s).transform_values { |v| normalize_header_value(v) }
      elsif headers.respond_to?(:to_hash)
        begin
          headers.to_hash.transform_keys(&:to_s).transform_values { |v| normalize_header_value(v) }
        rescue StandardError
          # fall through to other enumeration strategies
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
        elsif key_down.match?(SENSITIVE_HEADER_PATTERN)
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

    def sanitize_url(url)
      uri = URI.parse(url)
      return url unless uri.query

      params = URI.decode_www_form(uri.query)
      redacted = false
      params.map! do |n, v|
        if n.match?(SENSITIVE_QUERY_PARAM_PATTERN)
          redacted = true
          [n, "[REDACTED]"]
        else
          [n, v]
        end
      end

      if redacted
        uri.query = URI.encode_www_form(params)
        uri.to_s
      else
        url
      end
    rescue URI::InvalidURIError
      url
    end

    def send_complete_request_log(request_id:, method:, url:, request_headers:, request_body:, response_headers:,
      response_body:, status_code:, start_time:, end_time:, duration_ms:, is_streaming:, source_api: nil, model: nil)
      raw_request = {
        id: request_id,
        timestamp: start_time.iso8601,
        method: method.to_s.downcase,
        url: sanitize_url(url),
        headers: sanitize_headers(request_headers),
        request_body: request_body,
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

      api_service = Coolhand::ApiService.new
      api_service.send_llm_request_log(request_data)

      Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
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
