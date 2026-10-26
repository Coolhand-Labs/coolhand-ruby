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

      def eof?
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

      private

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
