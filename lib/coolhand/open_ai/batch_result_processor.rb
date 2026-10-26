# frozen_string_literal: true

require_relative "../../coolhand"

module Coolhand
  module OpenAi
    class BatchResultProcessor
      # Batch input/output files carry relative URLs (e.g. "/v1/chat/completions"); logs need the
      # absolute form so backend URL-shape classification matches the rest of the gem's OpenAI traffic.
      OPENAI_API_BASE_URL = "https://api.openai.com"
      SOURCE_API = "openai"
      # Real IDs look like "batch_<hex>" and "file-<alnum>" (Azure uses UUID tails with hyphens).
      # These values end up in OpenAI API calls made with the host app's key, so keep "/", "?", "#",
      # "." and whitespace out of them.
      BATCH_ID_PATTERN = /\Abatch_[A-Za-z0-9_-]{1,128}\z/
      FILE_ID_PATTERN = /\Afile[-_][A-Za-z0-9_-]{1,128}\z/

      attr_reader :event_data

      def initialize(event_data:)
        @event_data = event_data
      end

      def call
        Rails.logger.info("[Interceptor] BatchResultProcessor: #{event_data}")
        return unless valid_id?(event_data.is_a?(Hash) ? event_data["id"] : nil, BATCH_ID_PATTERN, "batch")

        case batch_info["status"]
        when "completed"
          # Downloads two files and POSTs one log per item — run it on the background log queue so
          # the webhook response isn't held up for the whole batch.
          LogQueue.submit(lane: :batch) { process_completed_batch_logging_errors }
        when "failed", "expired", "cancelled"
          handle_failed_batch
        when "in_progress", "validating", "finalizing"
          Rails.logger.info("[Interceptor] OpenAI batch #{event_data} still processing")
        else
          Rails.logger.warn("[Interceptor] Unknown batch status: #{batch_info['status']} for batch #{event_data}")
        end
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to process OpenAI batch results for #{event_data}: #{e.message}")
      end

      private

      # Runs on the batch lane's worker thread, where an escaping error would only reach
      # Coolhand.log (silenceable) rather than the Rails log `call` reports to.
      def process_completed_batch_logging_errors
        process_completed_batch
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to process OpenAI batch results for #{event_data}: #{e.message}")
      end

      def process_completed_batch
        input_file_id, output_file_id = result_file_ids
        return unless input_file_id && output_file_id

        window = batch_window
        return unless window

        request_items_by_id = {}
        each_batch_result(input_file_id) do |item, line_size|
          request_items_by_id[item["custom_id"]] ||= request_entry(item, line_size)
        end

        each_batch_result(output_file_id) do |response_item, line_size|
          request_item = request_items_by_id[response_item["custom_id"]]
          send_item_log(request_item, response_item, window, line_size) if request_item
        end

        Rails.logger.info("[Interceptor] Successfully processed OpenAI batch #{batch_info['id']}")
      end

      # Returns [input_file_id, output_file_id], or nil when either is absent (quietly: a completed
      # batch where every item failed legitimately has no output file) or malformed (logged).
      def result_file_ids
        input_file_id = batch_info["input_file_id"]
        output_file_id = batch_info["output_file_id"]
        return unless input_file_id && output_file_id
        return unless valid_id?(input_file_id, FILE_ID_PATTERN, "input file") &&
                      valid_id?(output_file_id, FILE_ID_PATTERN, "output file")

        [input_file_id, output_file_id]
      end

      def send_item_log(request_item, response_item, window, line_size)
        send_complete_request_log(request_item: request_item, response_item: response_item, window: window,
          line_size: line_size)
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to send request log: #{e.message}")
      end

      # What is kept of each input item while the output file is read: only the fields that get
      # logged, with the body capped (see BatchBodyCap) so the index stays small. The model is read
      # from the full body first, since a capped body is just a marker.
      def request_entry(item, line_size)
        { "method" => item["method"], "url" => item["url"], "model" => item_model(item["body"]),
          "body" => BatchBodyCap.cap(item["body"], source_size: line_size) }
      end

      # Returns [start_time, end_time] or nil (after logging) when OpenAI didn't report usable
      # in_progress_at/completed_at epoch seconds — better to skip than log epoch-0 timestamps.
      def batch_window
        started = batch_info["in_progress_at"]
        completed = batch_info["completed_at"]
        unless [started, completed].all? { |t| t.is_a?(Integer) && t.positive? }
          Rails.logger.error("[Interceptor] OpenAI batch #{batch_info['id']} has a missing or invalid " \
                             "in_progress_at/completed_at; skipping request log")
          return
        end

        warn_inverted_window if completed < started
        [Time.at(started), Time.at([started, completed].max)]
      end

      def warn_inverted_window
        Rails.logger.warn("[Interceptor] OpenAI batch #{batch_info['id']} has a completed_at before its " \
                          "in_progress_at; clamping duration_ms to 0")
      end

      def valid_id?(value, pattern, label)
        return true if value.is_a?(String) && value.match?(pattern)

        Rails.logger.error("[Interceptor] OpenAI batch has a missing or invalid #{label} ID " \
                           "(#{value.to_s[0, 100].inspect}); skipping")
        false
      end

      # Yields each item of a batch input/output file with the byte size of the JSONL line it came
      # from (nil when the client had already parsed it). A String/StringIO/IO result is read a line
      # at a time, so only one parsed item exists at once instead of the whole file split into lines.
      # A client that returns the whole file already parsed (an Array, or a Hash for a one-line file)
      # has loaded it already; that is out of reach here.
      def each_batch_result(file_id, &block)
        file_content = download_batch_file(file_id)

        case file_content
        when nil then nil
        when Array then file_content.each { |item| yield(item, nil) if item.is_a?(Hash) }
        when Hash then yield(file_content, nil)
        else each_jsonl_item(file_content, &block)
        end
      end

      def download_batch_file(file_id)
        client.files.content(id: file_id)
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to download OpenAI batch results: #{e.message}")
        nil
      end

      # A malformed line is skipped (JSONL lines are independent) and reported once at the end.
      def each_jsonl_item(file_content)
        skipped = 0
        file_content.each_line do |line|
          size = line.bytesize
          line = line.strip
          next if line.empty?

          item = parse_jsonl_line(line)
          item ? yield(item, size) : skipped += 1
        end
        return if skipped.zero?

        Rails.logger.error("[Interceptor] Failed to parse OpenAI batch results: skipped #{skipped} malformed line(s)")
      end

      # Only a JSON object is an item; any other valid JSON (a number, an array) counts as malformed.
      def parse_jsonl_line(line)
        item = JSON.parse(line)
        item if item.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def send_complete_request_log(request_item:, response_item:, window:, line_size:)
        start_time, end_time = window
        response = response_item["response"]
        BaseInterceptor.send_complete_request_log(
          request_id: response["request_id"],
          method: request_item["method"],
          url: absolute_url(request_item["url"]),
          source_api: SOURCE_API,
          model: request_item["model"] || item_model(response["body"]),
          request_headers: {},
          request_body: request_item["body"],
          response_headers: {},
          response_body: BatchBodyCap.cap(response["body"], source_size: line_size),
          status_code: response["status_code"],
          start_time: start_time,
          end_time: end_time,
          duration_ms: ((end_time - start_time) * 1000).to_i,
          is_streaming: false
        )
      end

      def absolute_url(url)
        url.is_a?(String) && url.start_with?("/") ? "#{OPENAI_API_BASE_URL}#{url}" : url
      end

      def item_model(*bodies)
        bodies.each do |body|
          model = body["model"] if body.is_a?(Hash)
          return model if model.is_a?(String) && Coolhand.required_field?(model)
        end
        nil
      end

      def batch_info
        @batch_info ||= client.batches.retrieve(id: event_data["id"])
      end

      def client
        @client ||= begin
          require "openai"
          OpenAI::Client.new
        rescue LoadError => e
          raise LoadError, "The 'openai' gem is required to process OpenAI batches. " \
                           "Install it with: gem 'openai'\n\nOriginal error: #{e.message}"
        end
      end

      # TODO: implement API to handle failed batch results and display errors on dashboard page
      def handle_failed_batch
        Rails.logger.error("[Interceptor] OpenAI batch #{batch_info['id']} failed: #{batch_info['errors']}")
      end
    end
  end
end
