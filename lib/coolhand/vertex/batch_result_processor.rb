module Coolhand
  module Vertex
    class BatchResultProcessor
      attr_reader :batch_info

      def initialize(batch_info:)
        @batch_info = batch_info
      end

      def call(batch_results)
        Rails.logger.info("[Interceptor] BatchResultProcessor: #{batch_info}")

        case batch_info["state"]
        when "JOB_STATE_PENDING", "JOB_STATE_RUNNING", "JOB_STATE_QUEUED"
          Rails.logger.info("[Interceptor] Vertex batch #{batch_info} still processing")
        when "JOB_STATE_SUCCEEDED"
          batch_results.each { |batch_item| process_completed_batch(batch_item) }
        when "JOB_STATE_FAILED"
          handle_failed_batch
        else
          Rails.logger.warn("[Interceptor] Unknown batch status: #{batch_info['state']} for batch #{batch_info}")
        end
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to process Vertex batch results for #{batch_info}: #{e.message}")
      end

      private

      def process_completed_batch(batch_item)
        send_complete_request_log(request_id: SecureRandom.hex(16),
                                  method: "POST",
                                  url: batch_info["name"],
                                  request_body: batch_item["request"],
                                  response_body: batch_item["response"],
                                  status_code: 200,
                                  start_time: batch_info["startTime"],
                                  end_time: batch_info["endTime"])

        Rails.logger.info("[Interceptor] Successfully processed Vertex batch #{batch_info["displayName"]}")
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to send request log: #{e.message}")
      end

      def send_complete_request_log(request_id:, method:, url:, request_body:, response_body:, status_code:,
                                    start_time:, end_time:)
        start_time = Time.iso8601(start_time)
        end_time   = Time.iso8601(end_time)
        duration_ms = ((end_time - start_time) * 1000).to_i

        request_data = {
          raw_request: {
            id: request_id,
            timestamp: start_time,
            method: method.to_s.downcase,
            url: url,
            headers: {},
            request_body: request_body,
            response_headers: {},
            response_body: response_body,
            status_code: status_code,
            duration_ms:,
            completed_at: end_time,
            is_streaming: false
          }
        }

        api_service = Coolhand::ApiService.new
        api_service.send_llm_request_log(request_data)

        Coolhand.log "📤 Sent complete request/response log for #{request_id} (duration: #{duration_ms}ms)"
      rescue StandardError => e
        Coolhand.log "❌ Error sending complete request log: #{e.message}"
      end

      # TODO: implement API to handle failed batch results and display errors on dashboard page
      def handle_failed_batch
        Rails.logger.error("[Interceptor] Vertex batch for #{batch_info["displayName"]} "\
                             "failed: #{batch_info["error"]["message"]}")
      end
    end
  end
end
