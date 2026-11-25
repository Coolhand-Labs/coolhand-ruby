# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "collector"
require_relative "errors"
require_relative "log_queue"
require_relative "post_delivery"
require_relative "read_requests"
require_relative "response_warnings"

module Coolhand
  class ApiService
    # The GET half of this class. See Coolhand::ReadRequests for why reads raise where writes
    # log and return nil.
    include ReadRequests
    include ResponseWarnings
    include PostDelivery

    # Caps how much of a failed response body is interpolated into a log line or an exception
    # message. Without it an oversized body from a proxy or gateway becomes the message.
    ERROR_BODY_LIMIT = 2000

    # How much of a failed response body is sanitized before it is cut to ERROR_BODY_LIMIT
    # characters (a character is at most 4 bytes).
    ERROR_BODY_SCAN_BYTES = ERROR_BODY_LIMIT * 4

    FEEDBACK_ID_LABELS = {
      llm_request_log_id: "LLM Request Log ID",
      llm_provider_unique_id: "Provider Unique ID",
      client_unique_id: "Client Unique ID"
    }.freeze
    private_constant :FEEDBACK_ID_LABELS

    attr_reader :api_endpoint

    def initialize(endpoint = "v2/llm_request_logs")
      @api_endpoint = "#{base_url}/#{endpoint}"
    end

    def send_llm_request_log(request_data)
      payload = {
        llm_request_log: request_data.merge(
          collector: Collector.get_collector_string
        )
      }

      if debug_mode?
        log_separator
        log "🛠️ Debug Mode - Request payload prepared but not sent to API:"
        log JSON.pretty_generate(sanitize_payload_for_json(payload))
        nil
      else
        result = send_request(payload, "✅ Successfully sent request metadata", background: LogQueue.worker_thread?)
        log_response_warnings(result)
        result
      end
    end

    def configuration
      Coolhand.configuration
    end

    def base_url
      configuration.base_url
    end

    def api_key
      configuration.api_key
    end

    def silent
      configuration.silent
    end

    def debug_mode?
      configuration.debug_mode
    end

    protected

    # Add collector field to the data being sent
    def add_collector_to_data(data, collection_method = nil)
      data.merge(collector: Collector.get_collector_string(collection_method))
    end

    def create_request_options(_payload)
      {
        "Content-Type" => "application/json",
        "X-API-Key" => api_key
      }
    end

    def log(*args)
      puts args.join(" ") unless silent
    end

    def log_separator
      log("═" * 60) unless silent
    end

    # Returns the parsed response, or nil on failure (and in debug mode, where nothing is sent). With
    # `raise_on_error`, a failure raises {Coolhand::HttpError} / {Coolhand::Error} instead.
    def create_feedback(feedback, collection_method = nil, raise_on_error: false)
      return reject_missing_key(raise_on_error) if !debug_mode? && missing_api_key?

      normalized = normalize_feedback_sentiment(feedback)
      feedback_with_collector = add_collector_to_data(normalized, collection_method)

      payload = {
        llm_request_log_feedback: feedback_with_collector
      }

      log_feedback_info(normalized)

      if debug_mode?
        log_separator
        log "🛠️ Debug Mode - Request payload prepared but not sent to API:"
        log JSON.pretty_generate(payload)
        nil
      else
        result = send_request(payload, "✅ Successfully created feedback #{feedback_identifier(feedback)}".strip,
          raise_on_error: raise_on_error)

        log_separator

        result
      end
    end

    def create_log(captured_data, collection_method = nil)
      return nil if !debug_mode? && missing_api_key?

      raw_request_with_collector = add_collector_to_data({ raw_request: captured_data }, collection_method)

      payload = {
        llm_request_log: raw_request_with_collector
      }

      log_request_info(captured_data)

      if debug_mode?
        log_separator
        log "🛠️ Debug Mode - Request payload prepared but not sent to API:"
        log JSON.pretty_generate(payload)
        nil
      else
        result = send_request(payload, "✅ Successfully logged to API", background: LogQueue.worker_thread?)

        puts "✅ Successfully logged to API with ID: #{result[:id]}" if result && !silent

        log_separator
        result
      end
    end

    # Filter list of known binary/problematic field names by service
    BINARY_DATA_FILTERS = {
      # ElevenLabs fields that contain binary audio data
      elevenlabs: %w[
        full_audio
        audio
        audio_data
        raw_audio
        audio_base64
        voice_sample
        audio_url
      ],
      # OpenAI fields that might contain binary data
      openai: %w[
        file_content
        audio_data
        image_data
        binary_content
      ]
    }.freeze

    private

    # Shared by the write path's failure log and the read path's raised message, so a large
    # response body never dumps a whole document into either. An HTML error page (a proxy's 502,
    # say) is cut short hard; anything else keeps enough to diagnose from and no more.
    def format_error_body(body)
      return nil if body.nil?

      # The body is server-controlled and ends up on the host's stdout, so strip control characters.
      # Only a bounded prefix is sanitized, so a multi-megabyte body costs no more than a small one.
      raw = body.to_s
      text = strip_control_characters(raw.byteslice(0, ERROR_BODY_SCAN_BYTES))
      return "#{text[0..200]}... [HTML error page truncated]" if text.include?("<!DOCTYPE html>")
      return text if text.length <= ERROR_BODY_LIMIT && raw.bytesize <= ERROR_BODY_SCAN_BYTES

      "#{text[0, ERROR_BODY_LIMIT]}... [truncated]"
    end

    def apply_headers(request, headers)
      headers.each do |key, value|
        # Net::HTTP rejects header values that are not UTF-8.
        request[key] = value.is_a?(String) ? value.dup.force_encoding("UTF-8") : value
      end
    end

    def missing_api_key?
      return false if Coolhand.required_field?(api_key)

      Coolhand.log "⚠️  Coolhand: API key is missing — skipping log for this request."
      true
    end

    # Get all filtered field names as a flat array
    def filtered_field_names
      @filtered_field_names ||= BINARY_DATA_FILTERS.values.flatten.map(&:downcase)
    end

    # Recursively sanitize payload to remove known problematic fields
    def sanitize_payload_for_json(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(key, value), sanitized|
          key_str = key.to_s.downcase

          # Skip if key matches any filtered field name
          next if filtered_field_names.any? { |filter| key_str.include?(filter) }

          sanitized[key] = sanitize_payload_for_json(value)
        end
      when Array
        obj.map { |item| sanitize_payload_for_json(item) }
      else
        obj
      end
    rescue StandardError => e
      log "⚠️ Warning: Error sanitizing payload: #{e.message}"
      obj
    end

    def normalize_feedback_sentiment(feedback)
      return feedback.except(:like) if feedback[:sentiment]
      return feedback if feedback[:like].nil?

      sentiment = feedback[:like] ? "like" : "dislike"
      feedback.except(:like).merge(sentiment: sentiment)
    end

    # The identifier the feedback is matched by, as [field, value]; nil when it has none.
    def feedback_match(feedback)
      field = FEEDBACK_ID_LABELS.keys.find { |name| feedback[name] }
      [field, feedback[field]] if field
    end

    # For the success message; "" when the feedback has no identifier.
    def feedback_identifier(feedback)
      field, value = feedback_match(feedback)
      field ? "(#{FEEDBACK_ID_LABELS[field]}: #{value})" : ""
    end

    def feedback_announcement(feedback)
      field, value = feedback_match(feedback)
      field ? "\n📝 CREATING FEEDBACK for #{FEEDBACK_ID_LABELS[field]}: #{value}" : "\n📝 CREATING FEEDBACK"
    end

    def log_feedback_info(feedback)
      return if silent

      puts feedback_announcement(feedback)

      puts "💬 Sentiment: #{feedback[:sentiment]}" if feedback[:sentiment]

      puts "🔗 Workload: #{feedback[:workload_hashid]}" if feedback[:workload_hashid]

      if feedback[:explanation]
        explanation = feedback[:explanation]
        truncated = explanation.length > 100 ? "#{explanation[0..99]}..." : explanation
        puts "💭 Explanation: #{truncated}"
      end

      puts "📤 Sending to: #{@api_endpoint}"
    end

    def log_request_info(captured_data)
      return if silent

      puts "\n🎉 LOGGING OpenAI API Call #{@api_endpoint}"

      if debug_mode?
        puts captured_data
      else
        puts request_body_summary(captured_data)
      end

      puts "📤 Sending to: #{@api_endpoint}"
    end

    def request_body_summary(captured_data)
      return "captured_data: (unavailable)" unless captured_data.is_a?(Hash)

      id = captured_data[:id] || captured_data["id"] || "N/A"
      body = captured_data[:request_body] || captured_data["request_body"]
      "id: #{id}, request_body: #{body.to_json.bytesize} bytes"
    rescue StandardError
      "captured_data: (unavailable)"
    end
  end
end
