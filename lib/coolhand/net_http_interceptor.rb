# frozen_string_literal: true

require "net/http"
require "openssl"
require "stringio"
require "timeout"
require "zlib"

module Coolhand
  module NetHttpInterceptor
    # Response streaming interceptor nested under NetHttpInterceptor
    module ResponseInterceptor
      def read_body(dest = nil, &block)
        # Only buffer this exact response while a #request call below is
        # actively capturing it — otherwise every block-form read_body in
        # the process (including ones on responses this gem never
        # intercepted, such as a nested request made from inside the host's
        # streaming block) accumulates into a thread-local that's never
        # freed, and leaks one request's chunks into another's log.
        return super unless block && Thread.current[:coolhand_capturing_stream].equal?(self)

        super do |chunk|
          Helpers.buffer_stream_chunk(chunk)
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
        rescue StandardError
          # Roll back this call's hold — it never actually took effect, so it must not count
          # toward the refcount or a legitimate later unpatch! would underflow against it. This
          # branch only runs when @patched was false on entry (see `next if @patched` above), so
          # forcing it back to false here is correct regardless of which line above raised —
          # including a failure in the second prepend, after the first already succeeded.
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
        Coolhand.log "🔌 Net::HTTP interceptor unpatched (capture stopped)"
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

      url = Helpers.capturable_url(self, req)
      return super unless url

      # Capture body before setting the guard — if this raises we skip logging cleanly
      # and the guard is never set, so there is no leak. A failure here (e.g. an
      # already-consumed body_stream) must never prevent the real request below
      # from being attempted — this gem must never be the reason the host
      # app's actual LLM call doesn't happen.
      captured_body = begin
        Helpers.capture_request_body(req, body)
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
      Thread.current[:coolhand_capturing_stream] = nil
      host_block_errors = []
      tracked_block = Helpers.track_streaming_block(block, host_block_errors)

      begin
        response = super(req, body, &tracked_block)
        captured = Thread.current[:coolhand_stream_buffer] || response&.body
        # captured is a String, or an Integer byte count when a streamed body overflowed the cap.
        response_body = Helpers.response_body_for_log(captured, response)
        status_code = response.respond_to?(:code) ? response.code.to_i : nil
      rescue StandardError => e
        status_code, response_body = Helpers.error_details(e, host_block_errors)
        raise
      ensure
        active.delete(self)
        Thread.current[:coolhand_stream_buffer] = previous_stream_buffer
        Thread.current[:coolhand_capturing_stream] = previous_capturing_stream
        end_time = Time.now
        duration_ms = ((end_time - start_time) * 1000).round(2)

        # Read here on the calling thread: the log worker thread has no access to our thread-locals.
        BaseInterceptor.send_complete_request_log(
          declared: DeclaredContext.current,
          request_id: request_id,
          method: req.method,
          url: url,
          request_headers: BaseInterceptor.sanitize_headers(req),
          request_body: captured_body,
          response_headers: BaseInterceptor.sanitize_headers(response),
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

    # Stateless helpers for #request. They live in their own namespaced module (not on the
    # prepended module itself) so the only method NetHttpInterceptor adds to Net::HTTP is
    # `request` — generically named helpers like `intercept?` would otherwise pollute
    # Net::HTTP and could collide with, or be shadowed by, other code.
    module Helpers
      module_function

      HOST_BLOCK_ERROR_MESSAGE = "[redacted: raised in host streaming block]"
      # Socket-level failures can surface inside the host's block (read_body runs there); they
      # carry no app data, so they keep their message even when they pass through the host block.
      TRANSPORT_ERRORS = [
        IOError, SystemCallError, Timeout::Error, Net::ProtocolError, OpenSSL::SSL::SSLError,
        Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error
      ].freeze
      private_constant :HOST_BLOCK_ERROR_MESSAGE, :TRANSPORT_ERRORS

      # Wraps the host's streaming block so (a) read_body only buffers the response being
      # captured here, and (b) exceptions raised by the host's own code can be told apart from
      # transport errors (see TRANSPORT_ERRORS). Returns nil when there is no block.
      def track_streaming_block(block, host_block_errors)
        return unless block

        proc do |res|
          Thread.current[:coolhand_capturing_stream] = res
          block.call(res)
        rescue StandardError => e
          host_block_errors << e unless transport_error?(e)
          raise
        end
      end

      # Matched by class, so a host block raising its own IOError/SystemCallError subclass keeps its
      # message too; accepted trade-off, as telling those apart from socket failures isn't possible.
      def transport_error?(error)
        TRANSPORT_ERRORS.any? { |klass| error.is_a?(klass) }
      end

      # An error raised by the host's streaming block can carry app-level data in its message (and
      # in a #status or message-embedded status code), so only its class is logged and no status is
      # derived from it; transport errors keep their message and status. Returns [status, body].
      def error_details(error, host_block_errors)
        from_host = host_block_errors.any? { |host_error| host_error.equal?(error) }
        status = from_host ? nil : extract_status_from_exception(error)
        message = from_host ? HOST_BLOCK_ERROR_MESSAGE : error.message
        [status, { "error" => { "class" => error.class.name, "message" => message } }]
      end

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
          # A declared Content-Length over the cap means we never need the bytes: skip
          # before .read so a huge stream is not buffered just to be discarded.
          too_large = oversized_declared_length(req)
          return too_large if too_large

          content = req.body_stream.read
          req.body_stream = StringIO.new(content)
        end
        return nil if content.nil?

        cap_and_parse(content, req)
      end

      # The effective cap: nil disables it; a non-Integer or negative value (e.g. an unparsed
      # ENV string) falls back to the default rather than raising into the host's request or stream.
      def capture_limit
        limit = Coolhand.configuration.max_captured_body_bytes
        return limit if limit.nil? || (limit.is_a?(Integer) && !limit.negative?)

        Coolhand::Configuration::DEFAULT_MAX_CAPTURED_BODY_BYTES
      end

      def over_capture_limit?(size)
        limit = capture_limit
        !limit.nil? && size > limit
      end

      def body_too_large_marker(carrier, size)
        skipped_capture_marker(carrier, "body_too_large", size_bytes: size, max_bytes: capture_limit)
      end

      # Returns a body_too_large marker when the request declares a Content-Length above the
      # cap, else nil. Chunked/absent/malformed lengths return nil (the caller then reads the
      # stream and cap_and_parse still enforces the cap on the real size).
      def oversized_declared_length(req)
        length = declared_content_length(req)
        body_too_large_marker(req, length) if length && over_capture_limit?(length)
      end

      def declared_content_length(req)
        req.content_length if req.respond_to?(:content_length)
      rescue StandardError
        nil
      end

      # Appends a streamed response chunk to the thread-local capture buffer, up to the cap.
      # Past the cap the buffer is dropped and replaced by a running byte count (an Integer),
      # so memory stays bounded; the host always still receives every chunk because the caller
      # yields it regardless. Only #request (via response_body_for_log) reads this slot.
      def buffer_stream_chunk(chunk)
        buffer = Thread.current[:coolhand_stream_buffer]
        total = (buffer.is_a?(Integer) ? buffer : buffer.to_s.bytesize) + chunk.bytesize

        Thread.current[:coolhand_stream_buffer] =
          if buffer.is_a?(Integer) || over_capture_limit?(total)
            total
          else
            (buffer || +"") << chunk
          end
      end

      # Builds the logged response body from either an Integer (streamed body that overflowed
      # the cap, see buffer_stream_chunk) or the body String/nil. An oversized String is
      # replaced by a marker before the dup/JSON.parse so we don't copy or parse it.
      def response_body_for_log(body, response)
        size = body.is_a?(Integer) ? body : body.to_s.bytesize
        return body_too_large_marker(response, size) if body.is_a?(Integer) || over_capture_limit?(size)

        body = body.dup.force_encoding("UTF-8") if body.is_a?(String)
        BaseInterceptor.parse_json(body)
      end

      def binary_upload?(req)
        content_type = req.respond_to?(:content_type) ? req.content_type : nil
        content_type && !content_type.match?(/json/i)
      end

      def cap_and_parse(content, req)
        return body_too_large_marker(req, content.bytesize) if over_capture_limit?(content.bytesize)

        BaseInterceptor.parse_json(content)
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

        host = uri.host.downcase.chomp(".")
        path = uri.path.to_s
        addresses = Coolhand.configuration.intercept_addresses
        authorities = [host, "#{host}:#{uri.port}"]
        return true if addresses.any? { |a| authorities.any? { |authority| address_matches?(authority, path, a) } }

        return false unless google_api_host_configured?(addresses)
        return false unless host == "googleapis.com" || host.end_with?(".googleapis.com")

        Coolhand.configuration.intercept_path_patterns.any? { |p| path.include?(p) }
      end

      # The capture decision runs before the host's real request, so a bad config value (e.g. a
      # non-array exclude_api_patterns) must degrade to "don't capture", never raise into the host.
      def capturable_url(http, req)
        url = build_url_for_request(http, req)
        url if intercept?(url) && should_capture?
      rescue StandardError => e
        Coolhand.log "⚠️ Skipping capture, could not evaluate intercept rules: #{e.class}"
        nil
      end

      def excluded_by_pattern?(uri)
        patterns = Coolhand.configuration.exclude_api_patterns
        return false if patterns.nil? || patterns.empty?

        path = uri.path.to_s
        matched = patterns.find { |pattern| path.include?(pattern) }
        if matched && Coolhand.configuration.debug_mode
          Coolhand.log "🚫 Skipping capture for #{BaseInterceptor.sanitize_url(uri.to_s)} " \
                       "(matched exclude_api_pattern: \"#{matched}\")"
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

      # An intercept_addresses entry may optionally pin a port ("host:port") and/or anchor to a
      # path prefix by embedding a "/" — e.g. "api.cohere.com/v2/chat" only matches requests to
      # that host whose path starts with "/v2/chat", and "cognitiveservices.azure.com/openai/" only
      # matches that multi-service Azure host's OpenAI paths, so unrelated endpoints on a shared
      # host aren't swept in alongside the ones we mean to capture.
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
end
