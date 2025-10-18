# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Coolhand
  module Ruby
    class ApiService
      BASE_URI = "https://coolhand.io/api"

      attr_reader :api_endpoint

      def initialize(endpoint_path)
        @api_endpoint = "#{BASE_URI}/#{endpoint_path}"
      end

      def configuration
        Coolhand.configuration
      end

      def api_key
        configuration.api_key
      end

      def silent
        configuration.silent
      end

      protected

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
        headers.each { |key, value| request[key] = value }
        request.body = JSON.generate(payload)

        begin
          response = http.request(request)

          if response.is_a?(Net::HTTPSuccess)
            result = JSON.parse(response.body, symbolize_names: true)
            log success_message
            result
          else
            puts "❌ Request failed: #{response.code} - #{response.body}"
            nil
          end
        rescue StandardError => e
          puts "❌ Request error: #{e.message}"
          nil
        end
      end

      def log(*args)
        puts args.join(" ") unless silent
      end

      def log_separator
        log("═" * 60) unless silent
      end

      def create_feedback(feedback)
        payload = {
          llm_request_log_feedback: feedback
        }

        log_feedback_info(feedback)

        result = send_request(
          payload,
          "✅ Successfully created feedback with ID: #{feedback[:llm_request_log_id] || 'N/A'}"
        )

        log_separator
        result
      end

      def create_log(captured_data)
        payload = {
          llm_request_log: {
            raw_request: captured_data
          }
        }

        log_request_info(captured_data)

        result = send_request(
          payload,
          "✅ Successfully logged to API"
        )

        puts "✅ Successfully logged to API with ID: #{result[:id]}" if result && !silent

        log_separator
        result
      end

      private

      def log_feedback_info(feedback)
        return if silent

        puts "\n📝 CREATING FEEDBACK for LLM Request Log ID: #{feedback[:llm_request_log_id]}"
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
end
