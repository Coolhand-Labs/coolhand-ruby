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

      start_time = Time.now
      request_id = SecureRandom.uuid

      Thread.current[:coolhand_stream_buffer] = nil
      response = super
      body_content = Thread.current[:coolhand_stream_buffer] || response&.body
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
        response_body: parse_json(body_content),
        status_code: response.respond_to?(:code) ? response.code.to_i : nil,
        start_time: start_time,
        end_time: end_time,
        duration_ms: duration_ms,
        is_streaming: !!block
      )

      response
    end

    private

    def intercept?(url)
      return false unless url && Coolhand.configuration.respond_to?(:intercept_addresses)

      Coolhand.configuration.intercept_addresses.any? { |a| url.include?(a) }
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
