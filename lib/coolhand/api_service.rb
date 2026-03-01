# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "collector"

module Coolhand
  class ApiService
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
      uri = URI.parse(@api_endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")

      request = Net::HTTP::Post.new(uri.request_uri)
      headers = create_request_options(payload)
      headers.each do |key, value|
        # Ensure header values are UTF-8 encoded
        encoded_value = value.is_a?(String) ? value.dup.force_encoding("UTF-8") : value
        request[key] = encoded_value
      end

      # Clean payload and ensure UTF-8 encoding before JSON generation
      cleaned_payload = sanitize_payload_for_json(payload)
      json_body = JSON.generate(cleaned_payload)

      # Ensure the request body is properly encoded as UTF-8
      request.body = json_body.force_encoding("UTF-8")

      begin
        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          result = JSON.parse(response.body, symbolize_names: true)
          log success_message
          result
        else
          body = response.body.force_encoding("UTF-8") if response.body
          # Only show first part of HTML error pages
          error_msg = if body&.include?("<!DOCTYPE html>")
            "#{body[0..200]}... [HTML error page truncated]"
          else
            body
          end
          log "❌ Request failed: #{response.code} - #{error_msg}"
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
      feedback_with_collector = add_collector_to_data(feedback, collection_method)

      payload = {
        llm_request_log_feedback: feedback_with_collector
      }

      log_feedback_info(feedback)

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

      puts "👍/👎 Like: #{feedback[:like]}"

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
