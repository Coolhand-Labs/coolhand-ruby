# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "collector"
require_relative "errors"
require_relative "read_requests"

module Coolhand
  class ApiService
    # The GET half of this class. See Coolhand::ReadRequests for why reads raise where writes
    # log and return nil.
    include ReadRequests

    # Caps how much of a failed response body is interpolated into a log line or an exception
    # message. Without it an oversized body from a proxy or gateway becomes the message.
    ERROR_BODY_LIMIT = 2000

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
        send_request(payload, "✅ Successfully sent request metadata")
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

    def send_request(payload, success_message)
      return nil if missing_api_key?

      uri = URI.parse(@api_endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      # Bound worst-case latency: this call happens inline in the intercepted
      # request's path, so a slow/unreachable Coolhand backend must not hang
      # the host app's real LLM call for Ruby's ~60s Net::HTTP defaults.
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.request_uri)
      apply_headers(request, create_request_options(payload))

      # Clean payload and ensure UTF-8 encoding before JSON generation
      cleaned_payload = sanitize_payload_for_json(payload)
      json_body = JSON.generate(cleaned_payload)

      # Ensure the request body is properly encoded as UTF-8
      request.body = json_body.force_encoding("UTF-8")

      begin
        # This request goes through the same patched Net::HTTP as the host
        # app's real LLM calls. Without this, a base_url/intercept_addresses
        # configuration that also matches Coolhand's own API host would
        # re-intercept this log-shipping call, generating a second log
        # request that itself gets intercepted, and so on — unbounded
        # request amplification.
        response = Coolhand.without_capture { http.request(request) }

        if response.is_a?(Net::HTTPSuccess)
          result = JSON.parse(response.body, symbolize_names: true)
          log success_message
          result
        else
          log "❌ Request failed: #{response.code} - #{format_error_body(response.body)}"
          nil
        end
      rescue StandardError => e
        log "❌ Request error: #{e.message}"
        nil
      end
    end

    def log(*args)
      puts args.join(" ") unless silent
    end

    def log_separator
      log("═" * 60) unless silent
    end

    def create_feedback(feedback, collection_method = nil)
      return nil if !debug_mode? && missing_api_key?

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
        result = send_request(
          payload,
          "✅ Successfully created feedback with ID: #{feedback[:llm_request_log_id] || 'N/A'}"
        )

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
        result = send_request(
          payload,
          "✅ Successfully logged to API"
        )

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

      text = body.dup.force_encoding("UTF-8")
      return "#{text[0..200]}... [HTML error page truncated]" if text.include?("<!DOCTYPE html>")
      return text if text.length <= ERROR_BODY_LIMIT

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

    def log_feedback_info(feedback)
      return if silent

      # Log the appropriate identifier based on what was provided
      if feedback[:llm_request_log_id]
        puts "\n📝 CREATING FEEDBACK for LLM Request Log ID: #{feedback[:llm_request_log_id]}"
      elsif feedback[:llm_provider_unique_id]
        puts "\n📝 CREATING FEEDBACK for Provider Unique ID: #{feedback[:llm_provider_unique_id]}"
      else
        puts "\n📝 CREATING FEEDBACK"
      end

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
      puts captured_data
      puts "📤 Sending to: #{@api_endpoint}"
    end
  end
end
