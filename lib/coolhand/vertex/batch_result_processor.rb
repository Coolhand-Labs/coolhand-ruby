# frozen_string_literal: true

require_relative "../../coolhand"

module Coolhand
  module Vertex
    class BatchResultProcessor
      # Global endpoint, not the job's region-specific one — matches the
      # "aiplatform.googleapis.com" entry in default_intercept_addresses.yml
      # so backend URL-shape classification stays consistent with the rest
      # of the gem's Vertex traffic. The URL this produces always contains
      # "/batchPredictionJobs/", which is also the default client-side
      # exclude_api_patterns entry — that's harmless here since this class
      # sends via BaseInterceptor/ApiService directly and never goes through
      # NetHttpInterceptor's intercept/exclude filtering.
      VERTEX_API_BASE_URL = "https://aiplatform.googleapis.com/v1/"
      SOURCE_API = "vertex"
      VALID_NAME_PATTERN = %r{\Aprojects/[^/?#\s]+/locations/[^/?#\s]+/batchPredictionJobs/[^/?#\s]+\z}

      attr_reader :batch_info, :model

      def initialize(batch_info:, model: nil)
        @batch_info = batch_info
        @model = model
      end

      def call(batch_results = [])
        Rails.logger.info("[Interceptor] BatchResultProcessor: #{batch_info}")

        case batch_info["state"]
        when "JOB_STATE_PENDING", "JOB_STATE_RUNNING", "JOB_STATE_QUEUED"
          Rails.logger.info("[Interceptor] Vertex batch #{batch_info} still processing")
        when "JOB_STATE_SUCCEEDED"
          process_completed_batch(batch_results)
        when "JOB_STATE_FAILED"
          handle_failed_batch
        else
          Rails.logger.warn("[Interceptor] Unknown batch status: #{batch_info['state']} for batch #{batch_info}")
        end
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to process Vertex batch results for #{batch_info}: #{e.message}")
      end

      private

      def process_completed_batch(batch_results)
        name = batch_info["name"].to_s.sub(%r{\A/+}, "")
        unless name.match?(VALID_NAME_PATTERN)
          Rails.logger.error("[Interceptor] Vertex batch #{batch_info['displayName']} has a missing or " \
                             "invalid job resource name (#{batch_info['name'].inspect}); skipping request log")
          return
        end

        begin
          start_time = Time.iso8601(batch_info["startTime"])
          end_time   = Time.iso8601(batch_info["endTime"])
        rescue TypeError, ArgumentError
          Rails.logger.error("[Interceptor] Vertex batch #{batch_info['displayName']} has a missing or " \
                             "invalid startTime/endTime; skipping request log")
          return
        end

        if end_time < start_time
          Rails.logger.warn("[Interceptor] Vertex batch #{batch_info['displayName']} has an endTime before " \
                            "its startTime; sending request log(s) with duration_ms clamped to 0")
          end_time = start_time
        end

        duration_ms = ((end_time - start_time) * 1000).to_i
        url = "#{VERTEX_API_BASE_URL}#{name}"
        resolved = resolved_model

        sent = batch_results.count do |batch_item|
          send_item_log(batch_item, url: url, model: resolved, start_time: start_time, end_time: end_time,
            duration_ms: duration_ms)
        end

        # "Sent" here means dispatched to BaseInterceptor without a local
        # error (e.g. a malformed batch_item) — BaseInterceptor swallows any
        # downstream delivery failure itself, so this can't confirm the
        # Coolhand API actually received the log.
        if sent == batch_results.size
          Rails.logger.info("[Interceptor] Dispatched #{sent} result(s) for Vertex batch " \
                            "#{batch_info['displayName']} for logging")
        else
          Rails.logger.warn("[Interceptor] Dispatched #{sent}/#{batch_results.size} result(s) for Vertex " \
                            "batch #{batch_info['displayName']} for logging — " \
                            "#{batch_results.size - sent} item(s) were malformed and skipped")
        end
      end

      def send_item_log(batch_item, url:, model:, start_time:, end_time:, duration_ms:)
        unless batch_item.is_a?(Hash) && (batch_item.key?("request") || batch_item.key?("response"))
          Rails.logger.error("[Interceptor] Vertex batch #{batch_info['displayName']} has a malformed result " \
                             "item (#{batch_item.class}); skipping request log")
          return false
        end

        BaseInterceptor.send_complete_request_log(
          request_id: SecureRandom.hex(16),
          method: "POST",
          url: url,
          source_api: SOURCE_API,
          model: model,
          request_headers: {},
          request_body: batch_item["request"],
          response_headers: {},
          response_body: batch_item["response"],
          status_code: 200,
          start_time: start_time,
          end_time: end_time,
          duration_ms: duration_ms,
          is_streaming: false
        )
        true
      rescue StandardError => e
        Rails.logger.error("[Interceptor] Failed to send request log: #{e.message}")
        false
      end

      def resolved_model
        candidate = [model, batch_info["model"]].find { |c| Coolhand.required_field?(c) }&.to_s&.strip
        return if candidate.nil?

        # Only normalize genuine Vertex model resource paths (e.g.
        # "publishers/google/models/gemini-2.0-flash" or
        # "projects/P/locations/L/models/M@1") down to their bare id. A
        # caller-supplied `model:` might itself be a provider-qualified slug
        # that happens to contain a slash (e.g. "meta-llama/Llama-3") —
        # leave anything that isn't a resource path untouched.
        candidate.match?(%r{\A(publishers|projects)/}) ? candidate.split("/").last : candidate
      end

      # TODO: implement API to handle failed batch results and display errors on dashboard page
      def handle_failed_batch
        Rails.logger.error("[Interceptor] Vertex batch for #{batch_info['displayName']} " \
                           "failed: #{batch_info['error']['message']}")
      end
    end
  end
end
