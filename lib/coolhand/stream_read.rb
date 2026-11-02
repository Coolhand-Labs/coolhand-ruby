# frozen_string_literal: true

module Coolhand
  module NetHttpInterceptor
    # Whether the host read a streamed response body to its end, tracked in thread-local state that
    # #request saves and restores around each call (like the stream buffer).
    module StreamRead
      module_function

      # Records how the host's first read of the body ended; a later read cannot undo it (after a
      # break, Net::HTTP itself reads the rest of the body once the host's block returns).
      def record(finished)
        Thread.current[:coolhand_stream_read] ||= finished ? :complete : :abandoned
      end

      # True when a response was handed to the host's streaming block and some of its body was
      # buffered, but it was not read to the end: the read was cut short (break, throw, raise, dropped
      # connection). With nothing buffered there is no partial body to mark, so the log is unchanged.
      # A body Net::HTTP read to its end is complete even if the host then raised.
      def incomplete?(completed)
        thread = Thread.current
        return false unless thread[:coolhand_capturing_stream] && thread[:coolhand_stream_buffer]

        read = thread[:coolhand_stream_read]
        read == :abandoned || (read.nil? && !completed)
      end

      # [status_code, response_body] for an abandoned stream: what was buffered so far.
      # Runs in #request's ensure, so it must not raise.
      def partial_response(response)
        buffered = Thread.current[:coolhand_stream_buffer]
        [response.code.to_i, NetHttpInterceptor::Helpers.response_body_for_log(buffered, response)]
      rescue StandardError => e
        Coolhand.log "❌ Error capturing partial response: #{e.message}"
        [nil, nil]
      end
    end
  end
end
