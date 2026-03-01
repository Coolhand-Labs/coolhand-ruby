# frozen_string_literal: true

module Coolhand
  module NetHttpInterceptor
    include BaseInterceptor

    # Response streaming interceptor nested under NetHttpInterceptor
    module ResponseInterceptor
      def read_body(dest = nil, &block)
        return super unless block

        super do |chunk|
          Thread.current[:coolhand_stream_buffer] ||= +""
          Thread.current[:coolhand_stream_buffer] << chunk
          yield(chunk)
        end
      end
    end

    def self.patch!
      return if @patched

      Net::HTTP.prepend(self)
      Net::HTTPResponse.prepend(ResponseInterceptor)

      @patched = true
      Coolhand.log "🔗 Net::HTTP interceptor patched"
    end

    def self.unpatch!
      # NOTE: With prepend, there's no clean way to unpatch
      # We'll mark it as unpatched so it can be re-patched
      @patched = false
      Coolhand.log "🔌 Faraday monitoring disabled ..."
    end

    def self.patched?
      @patched
    end

    def request(req, body = nil, &block)
      return super unless NetHttpInterceptor.patched?

      url = build_url_for_request(self, req)
      return super unless intercept?(url)
      return super unless should_capture?

      start_time = Time.now
      request_id = SecureRandom.uuid
      response = nil
      status_code = nil
      response_body = nil

      Thread.current[:coolhand_stream_buffer] = nil

      begin
        response = super
        body_content = Thread.current[:coolhand_stream_buffer] || response&.body
        status_code = response.respond_to?(:code) ? response.code.to_i : nil
        response_body = parse_json(body_content)
      rescue StandardError => e
        status_code = extract_status_from_exception(e)
        response_body = { "error" => { "class" => e.class.name, "message" => e.message } }
        raise
      ensure
        Thread.current[:coolhand_stream_buffer] = nil
        end_time = Time.now
        duration_ms = ((end_time - start_time) * 1000).round(2)

        send_complete_request_log(
          request_id: request_id,
          method: req.method,
          url: url,
          request_headers: sanitize_headers(req),
          request_body: parse_json(body || req.body),
          response_headers: sanitize_headers(response),
          response_body: response_body,
          status_code: status_code,
          start_time: start_time,
          end_time: end_time,
          duration_ms: duration_ms,
          is_streaming: !!block
        )
      end

      response
    end

    private

    def should_capture?
      return true if Coolhand.configuration.debug_mode

      override = Thread.current[:coolhand_capture_override]
      return override unless override.nil?

      Coolhand.configuration.capture
    end

    def extract_status_from_exception(e)
      return e.status if e.respond_to?(:status) && e.status.is_a?(Integer)
      return e.response.status if e.respond_to?(:response) && e.response.respond_to?(:status)

      match = e.message.to_s.match(/status[=:\s]+(\d{3})/)
      match ? match[1].to_i : nil
    end

    def intercept?(url)
      return false unless url && Coolhand.configuration.respond_to?(:intercept_addresses)
      return false if excluded_by_pattern?(url)

      Coolhand.configuration.intercept_addresses.any? { |a| url.include?(a) }
    end

    def excluded_by_pattern?(url)
      patterns = Coolhand.configuration.exclude_api_patterns
      return false if patterns.nil? || patterns.empty?

      matched = patterns.find { |pattern| url.include?(pattern) }
      if matched && Coolhand.configuration.debug_mode
        Coolhand.log "🚫 Skipping capture for #{url} (matched exclude_api_pattern: \"#{matched}\")"
      end
      !!matched
    end

    def build_url_for_request(http, req)
      return req.path if %r{\Ahttps?://}.match?(req.path)

      scheme = http.use_ssl? ? "https" : "http"
      host = http.address
      port = http.port
      default = http.use_ssl? ? 443 : 80

      url = "#{scheme}://#{host}"
      url << ":#{port}" if port != default
      url << req.path
      url
    end
  end
end
