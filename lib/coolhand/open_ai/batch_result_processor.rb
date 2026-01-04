module Coolhand
  module OpenAi
    class BatchResultProcessor
      attr_reader :event_data

      def initialize(event_data:)
        @event_data = event_data
      end

      def call
        Rails.logger.info("[Interceptor] BatchResultProcessor: #{event_data}")

        case batch_info["status"]
        when "completed"
          process_completed_batch
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

      def process_completed_batch
        input_file_id = batch_info["input_file_id"]
        return unless input_file_id

        output_file_id = batch_info["output_file_id"]
        return unless output_file_id

        # Download and process results
        batch_request_items = download_batch_results(input_file_id)

        # Download and process results
        batch_response_items = download_batch_results(output_file_id)

        batch_response_items.each do |response_item|
          request_item = batch_request_items.detect { |item| item["custom_id"] == response_item["custom_id"] }

          next unless request_item

          send_complete_request_log(request_id: response_item["response"]["request_id"],
                                    method: request_item["method"],
                                    url: request_item["url"],
                                    request_body: request_item["body"],
                                    response_body: response_item["response"]["body"],
                                    status_code: response_item["response"]["status_code"],
                                    start_time: batch_info["in_progress_at"].to_i,
                                    end_time: batch_info["completed_at"].to_i)
        rescue StandardError => e
          Rails.logger.error("[Interceptor] Failed to send request log: #{e.message}")
        end

        Rails.logger.info("[Interceptor] Successfully processed OpenAI batch #{batch_info["id"]}")
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

      def send_complete_request_log(request_id:, method:, url:, request_body:, response_body:, status_code:,
                                    start_time:, end_time:)
        timestamp = Time.at(start_time).iso8601
        completed_at = Time.at(end_time).iso8601
        duration_ms = ((end_time - start_time) * 1000).to_i

        request_data = {
          raw_request: {
            id: request_id,
            timestamp:,
            method: method.to_s.downcase,
            url: url,
            headers: {},
            request_body: request_body,
            response_headers: {},
            response_body: response_body,
            status_code: status_code,
            duration_ms:,
            completed_at:,
            is_streaming: false
          }
        }

        api_service = Coolhand::ApiService.new
        api_service.send_llm_request_log(request_data)

        Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
      rescue StandardError => e
        Coolhand.log "❌ Error sending complete request log: #{e.message}"
      end

      def batch_info
        @batch_info ||= client.batches.retrieve(id: event_data["id"])
      end

      def client
        @client ||= OpenAI::Client.new
      end

      # TODO: implement API to handle failed batch results and display errors on dashboard page
      def handle_failed_batch
        Rails.logger.error("[Interceptor] OpenAI batch #{batch_info["id"]} failed: #{batch_info['errors']}")
      end
    end
  end
end
