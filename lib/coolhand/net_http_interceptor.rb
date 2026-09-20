# frozen_string_literal: true

require "stringio"

module Coolhand
  module NetHttpInterceptor
    include BaseInterceptor

    # Response streaming interceptor nested under NetHttpInterceptor
    module ResponseInterceptor
      def read_body(dest = nil, &block)
        # Only buffer while a #request call below is actively capturing —
        # otherwise every block-form read_body in the process (including
        # ones on responses this gem never intercepted) accumulates into a
        # thread-local that's never freed, which is an unbounded memory
        # leak on any thread that streams large non-LLM responses.
        return super unless block && Thread.current[:coolhand_capturing_stream]

        super do |chunk|
          Thread.current[:coolhand_stream_buffer] ||= +""
          Thread.current[:coolhand_stream_buffer] << chunk
          yield(chunk)
        end
      end
    end

    @patch_mutex = Mutex.new
    @patch_count = 0
    @patched = false

    # patch!/unpatch! are reference-counted so concurrent/nested callers (e.g. overlapping
    # Coolhand.capture blocks across threads) compose safely — the interceptor only actually
    # unpatches once every outstanding caller has released it. Coolhand.configure's patch! is
    # never balanced by an unpatch!, so it permanently holds the count at >=1 for the process
    # lifetime once the gem is enabled; that's intentional, not a leak.
    #
    # Unlike before, patch! is no longer idempotent on its own — every call must be matched by
    # exactly one unpatch! to release it. A host app that calls Coolhand.configure more than once
    # (e.g. a reloader re-running an initializer) will hold an extra, permanent reference each
    # time rather than no-op'ing; harmless (interception simply stays on), but worth knowing.
    def self.patch!
      @patch_mutex.synchronize do
        @patch_count += 1
        next if @patched

        begin
          Net::HTTP.prepend(self)
          Net::HTTPResponse.prepend(ResponseInterceptor)

          @patched = true
          Coolhand.log "🔗 Net::HTTP interceptor patched"
        rescue StandardError
          # Roll back this call's hold — it never actually took effect, so it must not count
          # toward the refcount or a legitimate later unpatch! would underflow against it. This
          # branch only runs when @patched was false on entry (see `next if @patched` above), so
          # forcing it back to false here is correct regardless of which line above raised —
          # including a failure in the log call itself, after prepend already succeeded.
          @patch_count -= 1
          @patched = false
          raise
        end
      end
    end

    def self.unpatch!
      # NOTE: With prepend, there's no clean way to unpatch
      # We'll mark it as unpatched so it can be re-patched
      @patch_mutex.synchronize do
        @patch_count -= 1 if @patch_count.positive?
        next if @patch_count.positive? || !@patched

        @patched = false
        Coolhand.log "🔌 Faraday monitoring disabled ..."
      end
    end

    def self.patched?
      @patched
    end

    # Testing-only: force a clean slate. Real callers should only ever use balanced
    # patch!/unpatch! pairs.
    def self.reset!
      @patch_mutex.synchronize do
        @patch_count = 0
        @patched = false
      end
    end

    def request(req, body = nil, &block)
      return super unless NetHttpInterceptor.patched?

      active = (Thread.current[:coolhand_active_requests] ||= {}.compare_by_identity)
      return super if active.key?(self)

      url = build_url_for_request(self, req)
      return super unless intercept?(url)
      return super unless should_capture?

      # Capture body before setting the guard — if this raises we skip logging cleanly
      # and the guard is never set, so there is no leak. A failure here (e.g. an
      # already-consumed body_stream) must never prevent the real request below
      # from being attempted — this gem must never be the reason the host
      # app's actual LLM call doesn't happen.
      captured_body = begin
        capture_request_body(req, body)
      rescue StandardError => e
        Coolhand.log "❌ Error capturing request body: #{e.message}"
        nil
      end

      active[self] = true
      start_time = Time.now
      request_id = SecureRandom.uuid
      response = nil
      status_code = nil
      response_body = nil

      # Save/restore rather than just nil-ing: a request made from inside
      # this request's own streaming block (nested interception) would
      # otherwise clobber this request's in-progress buffer with its own
      # chunks, mixing one request's content into another's log.
      previous_stream_buffer = Thread.current[:coolhand_stream_buffer]
      previous_capturing_stream = Thread.current[:coolhand_capturing_stream]
      Thread.current[:coolhand_stream_buffer] = nil
      Thread.current[:coolhand_capturing_stream] = true

      begin
        response = super
        body_content = Thread.current[:coolhand_stream_buffer] || response&.body
        body_content = body_content.dup.force_encoding("UTF-8") if body_content.is_a?(String)
        status_code = response.respond_to?(:code) ? response.code.to_i : nil
        response_body = parse_json(body_content)
      rescue StandardError => e
        status_code = extract_status_from_exception(e)
        response_body = { "error" => { "class" => e.class.name, "message" => e.message } }
        raise
      ensure
        active.delete(self)
        Thread.current[:coolhand_stream_buffer] = previous_stream_buffer
        Thread.current[:coolhand_capturing_stream] = previous_capturing_stream
        end_time = Time.now
        duration_ms = ((end_time - start_time) * 1000).round(2)

        send_complete_request_log(
          request_id: request_id,
          method: req.method,
          url: url,
          request_headers: sanitize_headers(req),
          request_body: captured_body,
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

    def capture_request_body(req, body)
      # Check content-type before touching body_stream at all — for a binary
      # upload (multipart/form-data, audio/*, etc.) this avoids reading the
      # stream into memory a second time just to build a log entry no one
      # can read anyway.
      return skipped_capture_marker(req, "non_json_content_type") if binary_upload?(req)

      content = body || req.body
      if content.nil? && req.respond_to?(:body_stream) && req.body_stream
        content = req.body_stream.read
        req.body_stream = StringIO.new(content)
      end
      return nil if content.nil?

      cap_and_parse(content, req)
    end

    def binary_upload?(req)
      content_type = req.respond_to?(:content_type) ? req.content_type : nil
      content_type && !content_type.match?(/json/i)
    end

    def cap_and_parse(content, req)
      max_bytes = Coolhand.configuration.max_captured_body_bytes
      if max_bytes && content.bytesize > max_bytes
        return skipped_capture_marker(req, "body_too_large", size_bytes: content.bytesize, max_bytes: max_bytes)
      end

      parse_json(content)
    end

    def skipped_capture_marker(req, reason, extra = {})
      marker = { "_coolhand_capture_skipped" => reason }.merge(extra.transform_keys(&:to_s))
      content_type = req.respond_to?(:content_type) ? req.content_type : nil
      marker["content_type"] = content_type if content_type
      marker
    end

    def extract_status_from_exception(e)
      return e.status if e.respond_to?(:status) && e.status.is_a?(Integer)
      return e.response.status if e.respond_to?(:response) && e.response.respond_to?(:status)

      match = e.message.to_s.match(/status[=:\s]+(\d{3})/)
      match ? match[1].to_i : nil
    end

    def intercept?(url)
      return false unless url && Coolhand.configuration.respond_to?(:intercept_addresses)

      uri = safe_parse(url)
      return false unless uri&.host

      return false if excluded_by_pattern?(uri)

      host = uri.host.downcase
      path = uri.path.to_s
      addresses = Coolhand.configuration.intercept_addresses
      return true if addresses.any? { |a| address_matches?(host, path, a) }
      return true if addresses.any? { |a| address_matches?("#{host}:#{uri.port}", path, a) }

      return false unless google_api_host_configured?(addresses)
      return false unless host == "googleapis.com" || host.end_with?(".googleapis.com")

      Coolhand.configuration.intercept_path_patterns.any? { |p| path.include?(p) }
    end

    def excluded_by_pattern?(uri)
      patterns = Coolhand.configuration.exclude_api_patterns
      return false if patterns.nil? || patterns.empty?

      path = uri.path.to_s
      matched = patterns.find { |pattern| path.include?(pattern) }
      if matched && Coolhand.configuration.debug_mode
        Coolhand.log "🚫 Skipping capture for #{sanitize_url(uri.to_s)} (matched exclude_api_pattern: \"#{matched}\")"
      end
      !!matched
    end

    # intercept_path_patterns only ever applies to googleapis.com hosts, and only when the
    # user still wants Google API traffic intercepted at all — otherwise overriding
    # intercept_addresses to exclude Google hosts wouldn't actually stop Google API capture.
    def google_api_host_configured?(addresses)
      addresses.any? do |a|
        a = a.to_s.downcase
        a == "googleapis.com" || a.end_with?(".googleapis.com")
      end
    end

    # An intercept_addresses entry may optionally anchor to a path prefix by embedding a "/" —
    # e.g. "cognitiveservices.azure.com/openai/" only matches requests to that host whose path
    # also starts with "/openai/", so Azure AI Services traffic for Speech/Vision/Language/
    # Content Safety on the same multi-service host isn't swept in alongside OpenAI calls.
    # The match is on a path *segment* boundary (trailing "/" on the pattern is optional and
    # stripped before comparing), so "host.com/openai" matches "/openai" and "/openai/x" but not
    # a same-prefix-but-different-segment path like "/openaiz".
    def address_matches?(host, path, pattern)
      host_pattern, sep, path_pattern = pattern.to_s.partition("/")
      return host_matches?(host, host_pattern) if sep.empty?
      return false unless host_matches?(host, host_pattern)

      path_pattern = path_pattern.delete_suffix("/")
      return true if path_pattern.empty?

      prefix = "/#{path_pattern}"
      path == prefix || path.start_with?("#{prefix}/")
    end

    # Host-boundary match: exact, or a dot-delimited suffix (case-insensitive).
    # A single "*" in `pattern` matches exactly one host label, e.g.
    # "bedrock-runtime.*.amazonaws.com" matches "bedrock-runtime.us-east-1.amazonaws.com".
    def host_matches?(host, pattern)
      pattern = pattern.to_s.downcase
      return host == pattern || host.end_with?(".#{pattern}") unless pattern.include?("*")

      regex = /\A#{pattern.split('*', -1).map { |part| Regexp.escape(part) }.join('[^.]+')}\z/
      !!(host =~ regex)
    end

    def safe_parse(url)
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
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
