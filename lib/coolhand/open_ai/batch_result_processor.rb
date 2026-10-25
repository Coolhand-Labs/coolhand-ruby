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

        request_items_by_id = download_batch_results(input_file_id).each_with_object({}) do |item, index|
          index[item["custom_id"]] ||= item
        end

        download_batch_results(output_file_id).each do |response_item|
          request_item = request_items_by_id[response_item["custom_id"]]
          send_item_log(request_item, response_item, window) if request_item
        end

        Rails.logger.info("[Interceptor] Successfully processed OpenAI batch #{batch_info['id']}")
      end

      # Returns [input_file_id, output_file_id], or nil when either is absent or malformed.
      def result_file_ids
        input_file_id = batch_info["input_file_id"]
        output_file_id = batch_info["output_file_id"]
        return unless input_file_id && output_file_id
        return unless valid_id?(input_file_id, FILE_ID_PATTERN, "input file") &&
                      valid_id?(output_file_id, FILE_ID_PATTERN, "output file")

        [input_file_id, output_file_id]
      end

      def send_item_log(request_item, response_item, window)
        send_complete_request_log(request_item: request_item, response_item: response_item, window: window)
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to send request log: #{e.message}")
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

        if completed < started
          Rails.logger.warn("[Interceptor] OpenAI batch #{batch_info['id']} has a completed_at before its " \
                            "in_progress_at; sending request log(s) with duration_ms clamped to 0")
          completed = started
        end

        [Time.at(started), Time.at(completed)]
      end

      def valid_id?(value, pattern, label)
        return true if value.is_a?(String) && value.match?(pattern)

        Rails.logger.error("[Interceptor] OpenAI batch has a missing or invalid #{label} ID " \
                           "(#{value.to_s[0, 100].inspect}); skipping")
        false
      end

      def download_batch_results(file_id)
        file_content = client.files.content(id: file_id)

        # Handle both string and array responses from the OpenAI client
        if file_content.is_a?(Array)
          # Client already parsed the JSONL into an array
          file_content
        else
          # Parse JSONL response manually
          file_content.split("\n").filter_map do |line|
            line.strip!
            next if line.empty?

            JSON.parse(line)
          end
        end
      rescue JSON::ParserError => e
        Rails.logger.error("[Interceptor] Failed to parse OpenAI batch results: #{e.message}")
        []
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to download OpenAI batch results: #{e.message}")
        []
      end

      def send_complete_request_log(request_item:, response_item:, window:)
        start_time, end_time = window
        response = response_item["response"]
        BaseInterceptor.send_complete_request_log(
          request_id: response["request_id"],
          method: request_item["method"],
          url: absolute_url(request_item["url"]),
          source_api: SOURCE_API,
          model: item_model(request_item["body"], response["body"]),
          request_headers: {},
          request_body: request_item["body"],
          response_headers: {},
          response_body: response["body"],
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
          return model if Coolhand.required_field?(model)
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
