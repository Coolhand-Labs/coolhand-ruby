# frozen_string_literal: true

module Coolhand
  module NetHttpInterceptor
    # Stands in for a request's body_stream while Net::HTTP sends it, copying the bytes that pass
    # through into a buffer capped at max_captured_body_bytes. The host's stream is read exactly
    # once, by Net::HTTP, in the same chunks as without the gem; nothing is read ahead, buffered in
    # full or rewound. Past the cap the buffer is dropped and only a byte count is kept, so memory
    # stays bounded however large the upload is.
    #
    # Deliberately exposes nothing but #read (and #readpartial, only when the source has it): a
    # delegating wrapper would also expose #to_io, which lets IO.copy_stream bypass the tap and read
    # the underlying file directly.
    class BodyStreamTap
      attr_reader :source, :bytes_seen

      # IO.copy_stream also accepts a path (String) or a Pathname as its source, reading the file
      # itself; the tap only offers #read, which those don't support, so they are left untouched.
      def self.tappable?(stream)
        stream.respond_to?(:read) && !stream.is_a?(String) &&
          (stream.respond_to?(:to_io) || !stream.respond_to?(:to_path))
      end

      def self.install(req)
        tap = new(req.body_stream)
        req.body_stream = tap
        tap
      end

      def initialize(source)
        @source = source
        @buffer = +"".b
        @bytes_seen = 0
        @eof = false
        @failed = false
        define_singleton_method(:readpartial) { |*args| read_partial(*args) } if source.respond_to?(:readpartial)
      end

      def read(*args)
        data = @source.read(*args)
        record(data, finished: args.empty? || args.first.nil? || data.nil?)
        data
      end

      # Whether the source has been read to its end (not IO#eof?: false until a read hits the end).
      def reached_end?
        @eof
      end

      # The capture itself failed (not the host's stream); the request body is simply not logged.
      def failed?
        @failed
      end

      def overflowed?
        @buffer.nil? && !@failed
      end

      def body
        @buffer&.dup&.force_encoding(Encoding::UTF_8)
      end

      # Puts the host's own stream back, unless something else has replaced the tap since.
      def restore_stream(req)
        req.body_stream = @source if req.body_stream.equal?(self)
      end

      # The request body for the log once the request has been attempted. Over the cap is known
      # from the bytes seen so far, even if the stream was not fully sent. Otherwise a stream that
      # never reached its end (the request failed first) has no complete body.
      def body_for_log(req)
        helpers = NetHttpInterceptor::Helpers
        return if failed?
        return helpers.body_too_large_marker(req, bytes_seen) if overflowed?
        return incomplete_marker(req) unless reached_end?

        BaseInterceptor.parse_json(body)
      end

      private

      def incomplete_marker(req)
        NetHttpInterceptor::Helpers.skipped_capture_marker(req, "body_stream_incomplete", size_bytes: bytes_seen)
      end

      def read_partial(*args)
        data = @source.readpartial(*args)
        record(data)
        data
      rescue EOFError
        @eof = true
        raise
      end

      # Runs inside the host's request send: whatever goes wrong here must never reach the host.
      def record(data, finished: false)
        @eof ||= finished
        return unless data.is_a?(String)

        @bytes_seen += data.bytesize
        return unless @buffer

        @buffer = NetHttpInterceptor::Helpers.over_capture_limit?(@bytes_seen) ? nil : @buffer << data.b
      rescue StandardError => e
        @failed = true
        @buffer = nil
        Coolhand.log "❌ Error capturing request body_stream: #{e.message}"
      end
    end
  end
end
