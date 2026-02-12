# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::LoggerService do
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-api-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { Coolhand::LoggerService.new }

  # Mock Rails ActionDispatch::Http::Headers behavior - shared across tests
  let(:mock_rails_headers_class) do
    Class.new do
      def initialize(headers_hash)
        @headers = headers_hash
      end

      def each(&block)
        @headers.each(&block)
      end

      # Rails headers don't respond to empty?
      def respond_to?(method)
        return false if method == :empty?

        super
      end

      def respond_to_missing?(method, include_private = false)
        method == :empty? ? false : super
      end

      # Rails headers don't have empty? method
      def method_missing(method, *args)
        raise NoMethodError, "undefined method `#{method}' for #{self.class}" if method == :empty?

        super
      end
    end
  end

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  describe "LoggerService#forward_webhook with Rails-like headers" do
    let(:webhook_body) do
      {
        "type" => "post_call_transcription",
        "data" => {
          "conversation_id" => "conv_123",
          "transcript" => [
            { "role" => "user", "message" => "Hello" },
            { "role" => "agent", "message" => "Hi there!" }
          ],
          "full_audio" => "base64audiodata",
          "tokens" => "[FILTERED]"
        }
      }
    end

    context "with Rails ActionDispatch-like headers object" do
      let(:rails_headers) do
        mock_rails_headers_class.new({
          "HTTP_CONTENT_TYPE" => "application/json",
          "HTTP_X_SIGNATURE" => "sha256=abc123",
          "HTTP_AUTHORIZATION" => "Bearer secret_token",
          "HTTP_X_ELEVENLABS_SIGNATURE" => "wsec_12345",
          "HTTP_USER_AGENT" => "ElevenLabs-Webhook/1.0"
        })
      end

      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 123 }))
      end

      it "does not raise NoMethodError when checking empty?" do
        expect do
          service.forward_webhook(
            webhook_body: webhook_body,
            source: "elevenlabs",
            headers: rails_headers
          )
        end.not_to raise_error
      end

      it "successfully forwards webhook with Rails headers" do
        result = service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          event_type: "post_call_transcription",
          headers: rails_headers
        )

        expect(result).not_to be_nil
        expect(result[:id]).to eq(123)
      end

      it "properly sanitizes Rails headers" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          headers: rails_headers
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            headers = body.dig("llm_request_log", "raw_request", "headers")

            # Check proper header conversion and sanitization
            expect(headers["content-type"]).to eq("application/json")
            expect(headers["x-signature"]).to eq("[REDACTED]")
            expect(headers["authorization"]).to eq("[REDACTED]")
            expect(headers["x-elevenlabs-signature"]).to eq("[REDACTED]")
            expect(headers["user-agent"]).to eq("ElevenLabs-Webhook/1.0")
            true
          end)
      end
    end

    context "with edge cases that previously caused errors" do
      it "handles headers that throw NoMethodError on empty?" do
        # Create a headers object that aggressively throws NoMethodError
        headers_with_error = Object.new
        def headers_with_error.each
          yield("HTTP_CONTENT_TYPE", "application/json")
        end

        def headers_with_error.respond_to?(_method)
          false
        end

        def headers_with_error.empty?
          raise NoMethodError, "undefined method `empty?' for ActionDispatch::Http::Headers"
        end

        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 456 }))

        expect do
          result = service.forward_webhook(
            webhook_body: webhook_body,
            source: "elevenlabs",
            headers: headers_with_error
          )
          expect(result).not_to be_nil
        end.not_to raise_error
      end

      it "handles nil headers gracefully" do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 789 }))

        result = service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          headers: nil
        )

        expect(result).not_to be_nil
        expect(result[:id]).to eq(789)
      end

      it "handles empty hash headers" do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 101 }))

        result = service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          headers: {}
        )

        expect(result).not_to be_nil
        expect(result[:id]).to eq(101)
      end

      it "handles headers with mixed case and special characters" do
        mixed_headers = mock_rails_headers_class.new({
          "HTTP_X_API_KEY" => "key123",
          "HTTP_X_SECRET_TOKEN" => "secret456",
          "HTTP_CONTENT_TYPE" => "application/json; charset=UTF-8",
          "HTTP_X_WEBHOOK_SECRET" => "webhook789",
          "HTTP_X_REQUEST_ID" => "req_abc123"
        })

        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 202 }))

        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          headers: mixed_headers
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            headers = body.dig("llm_request_log", "raw_request", "headers")

            # All sensitive headers should be redacted
            expect(headers["x-api-key"]).to eq("[REDACTED]")
            expect(headers["x-secret-token"]).to eq("[REDACTED]")
            expect(headers["x-webhook-secret"]).to eq("[REDACTED]")
            expect(headers["content-type"]).to eq("application/json; charset=UTF-8")
            expect(headers["x-request-id"]).to eq("req_abc123")
            true
          end)
      end
    end

    context "with real-world ElevenLabs webhook scenario" do
      let(:elevenlabs_webhook_data) do
        {
          "type" => "post_call_transcription",
          "event_timestamp" => 1_764_606_520,
          "data" => {
            "agent_id" => "agent_2401kb8azmd5f5881p966a4r33dx",
            "conversation_id" => "conv_1801kbdbwh2deqnbtnwt38avh37y",
            "status" => "done",
            "transcript" => [
              {
                "role" => "agent",
                "message" => "Hi there! I'm here to help.",
                "time_in_call_secs" => 0,
                "conversation_turn_metrics" => {
                  "metrics" => {
                    "convai_tts_service_ttfb" => { "elapsed_time" => 0.181 }
                  }
                }
              },
              {
                "role" => "user",
                "message" => "can you explain stuttering to me",
                "time_in_call_secs" => 16
              }
            ],
            "metadata" => {
              "call_duration_secs" => 25,
              "cost" => 276,
              "deletion_settings" => {
                "deleted_audio_at_time_unix_secs" => "[FILTERED]",
                "delete_audio" => "[FILTERED]"
              },
              "charging" => {
                "llm_usage" => {
                  "irreversible_generation" => {
                    "model_usage" => {
                      "gemini-2.0-flash-lite" => {
                        "input" => { "tokens" => "[FILTERED]", "price" => 0.000162 }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      end

      let(:elevenlabs_headers) do
        mock_rails_headers_class.new({
          "HTTP_CONTENT_TYPE" => "application/json",
          "HTTP_X_ELEVENLABS_SIGNATURE" => "wsec_787b497692eb18818de2357b5c261c997d4fad3db9d68fe8cbbc0adb35ec693a",
          "HTTP_USER_AGENT" => "ElevenLabs-Webhook/1.0",
          "HTTP_HOST" => "deliberatively-practised-reynaldo.ngrok-free.dev",
          "HTTP_X_FORWARDED_FOR" => "34.59.11.47"
        })
      end

      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 303, created_at: Time.now.iso8601 }))
      end

      it "processes a complete ElevenLabs webhook without errors" do
        result = service.forward_webhook(
          webhook_body: elevenlabs_webhook_data,
          source: "elevenlabs",
          event_type: elevenlabs_webhook_data["type"],
          headers: elevenlabs_headers,
          conversation_id: elevenlabs_webhook_data.dig("data", "conversation_id")
        )

        expect(result).not_to be_nil
        expect(result[:id]).to eq(303)
      end

      it "filters sensitive data from ElevenLabs webhooks" do
        service.forward_webhook(
          webhook_body: elevenlabs_webhook_data,
          source: "elevenlabs",
          event_type: "post_call_transcription",
          headers: elevenlabs_headers
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            request_body = body.dig("llm_request_log", "raw_request", "request_body")
            headers = body.dig("llm_request_log", "raw_request", "headers")

            # Check that sensitive headers are redacted
            expect(headers["x-elevenlabs-signature"]).to eq("[REDACTED]")

            # The field shouldn't exist as it was marked as [FILTERED] in the input
            # Our filtering removes the entire field, not just the value
            expect(request_body.dig("data", "metadata",
              "deletion_settings")).not_to have_key("deleted_audio_at_time_unix_secs")

            # Check that transcript data is preserved
            expect(request_body.dig("data", "transcript")).to be_an(Array)
            expect(request_body.dig("data", "transcript").first["message"]).to eq("Hi there! I'm here to help.")

            # Check URL is correctly formatted
            expect(body.dig("llm_request_log", "raw_request",
              "url")).to eq("webhook://elevenlabs/post_call_transcription")

            true
          end)
      end
    end
  end

  describe "regression prevention" do
    it "ensures sanitize_headers method is defensive against Rails objects" do
      service_class = Class.new(Coolhand::LoggerService) do
        public :sanitize_headers
      end
      test_service = service_class.new

      # Test various header-like objects
      test_cases = [
        nil,
        {},
        { "HTTP_TEST" => "value" },
        mock_rails_headers_class.new({ "HTTP_TEST" => "value" }),
        Object.new # Object that doesn't respond to each
      ]

      test_cases.each do |test_headers|
        expect { test_service.sanitize_headers(test_headers) }.not_to raise_error
      end
    end

    it "verifies the respond_to? check for empty? method" do
      service_class = Class.new(Coolhand::LoggerService) do
        public :sanitize_headers
      end
      test_service = service_class.new

      # Create an object that lies about having empty? but throws error
      tricky_headers = Object.new
      def tricky_headers.respond_to?(method)
        method == :empty? ? true : super
      end

      def tricky_headers.empty?
        raise NoMethodError, "Surprise! I don't really have empty?"
      end

      def tricky_headers.each
        yield("HTTP_TEST", "value")
      end

      # Should handle this gracefully - the error from empty? should be caught
      expect { test_service.sanitize_headers(tricky_headers) }.to raise_error(NoMethodError, /Surprise/)
    end
  end
end
