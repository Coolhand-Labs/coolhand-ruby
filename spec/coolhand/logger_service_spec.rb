# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::LoggerService do
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-api-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true)
  end
  let(:service) { described_class.new }

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  describe "#initialize" do
    it "configures with the provided endpoint" do
      expect(service.api_endpoint).to eq("https://coolhandlabs.com/api/v2/llm_request_logs")
    end
  end

  describe "#log_to_api" do
    let(:captured_data) do
      {
        id: "uuid-123",
        timestamp: "2023-01-01T00:00:00Z",
        method: "POST",
        url: "https://api.openai.com/v1/chat/completions",
        headers: { "Authorization" => "Bearer [REDACTED]" },
        request_body: { model: "gpt-4", messages: [] },
        response_body: { choices: [] },
        response_headers: { "content-type" => "application/json" },
        status_code: 200
      }
    end

    context "when API call is successful" do
      let(:mock_response) do
        {
          id: 789,
          created_at: "2023-01-01T00:00:00Z"
        }
      end

      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with(
            headers: {
              "Content-Type" => "application/json",
              "X-API-Key" => "test-api-key"
            }
          )
          .to_return(
            status: 200,
            body: JSON.generate(mock_response),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "successfully logs request data" do
        result = service.log_to_api(captured_data)

        expect(result).not_to be_nil
        expect(result[:id]).to eq(789)
      end

      it "structures payload correctly" do
        service.log_to_api(captured_data)

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            expect(body).to have_key("llm_request_log")
            expect(body["llm_request_log"]).to have_key("raw_request")
            expect(body["llm_request_log"]["raw_request"]["id"]).to eq("uuid-123")
            expect(body["llm_request_log"]["raw_request"]["method"]).to eq("POST")
          end)
      end

      it "includes collector field with auto-monitor method" do
        service.log_to_api(captured_data)

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            payload = body["llm_request_log"]

            # Check that collector field is present and has auto-monitor method
            expect(payload).to have_key("collector")
            expect(payload["collector"]).to eq("coolhand-ruby-#{Coolhand::VERSION}-auto-monitor")
          end)
      end
    end

    context "when API call fails" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "handles failed API response gracefully" do
        result = service.log_to_api(captured_data)
        expect(result).to be_nil
      end
    end

    context "with logging behavior" do
      context "when in silent mode" do
        it "does not output logs" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { service.log_to_api(captured_data) }.not_to output(/LOGGING OpenAI/).to_stdout
        end
      end

      context "when not in silent mode" do
        let(:verbose_config) do
          instance_double(Coolhand::Configuration,
            api_key: "test-api-key",
            base_url: "https://coolhandlabs.com/api",
            silent: false)
        end

        let(:verbose_service) do
          allow(Coolhand).to receive(:configuration).and_return(verbose_config)
          described_class.new
        end

        it "outputs verbose logs" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.log_to_api(captured_data) }
            .to output(/🎉 LOGGING OpenAI/).to_stdout
        end
      end
    end
  end

  describe "#forward_webhook" do
    let(:webhook_body) do
      {
        "type" => "post_call_transcription",
        "data" => {
          "conversation_id" => "conv_123",
          "transcript" => [
            { "role" => "user", "message" => "Hello" },
            { "role" => "agent", "message" => "Hi there!" }
          ],
          "full_audio" => "base64audiodata"
        }
      }
    end

    let(:headers) do
      {
        "HTTP_CONTENT_TYPE" => "application/json",
        "HTTP_X_SIGNATURE" => "sha256=abc123",
        "HTTP_AUTHORIZATION" => "Bearer secret_token"
      }
    end

    before do
      stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
        .to_return(status: 200, body: JSON.generate({ id: 123 }))
    end

    context "with valid parameters" do
      it "forwards webhook successfully" do
        result = service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          event_type: "post_call_transcription",
          headers: headers
        )

        expect(result).not_to be_nil
      end

      it "creates correct webhook URL with event type" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          event_type: "post_call_transcription"
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            url = body.dig("llm_request_log", "raw_request", "url")
            expect(url).to eq("webhook://elevenlabs/post_call_transcription")
          end)
      end

      it "creates correct webhook URL without event type" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs"
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            url = body.dig("llm_request_log", "raw_request", "url")
            expect(url).to eq("webhook://elevenlabs")
          end)
      end

      it "sets source as webhook source" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs"
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            source = body.dig("llm_request_log", "raw_request", "source")
            expect(source).to eq("elevenlabs_webhook")
          end)
      end

      it "includes custom fields in webhook data" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          conversation_id: "conv_123",
          agent_id: "agent_456",
          metadata: { "custom" => "data" }
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            raw_request = body.dig("llm_request_log", "raw_request")
            expect(raw_request["conversation_id"]).to eq("conv_123")
            expect(raw_request["agent_id"]).to eq("agent_456")
            expect(raw_request["metadata"]).to eq({ "custom" => "data" })
          end)
      end

      it "filters out binary data for elevenlabs" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs"
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            request_body = body.dig("llm_request_log", "raw_request", "request_body")
            expect(request_body.dig("data", "full_audio")).to be_nil
            expect(request_body.dig("data", "transcript")).not_to be_nil
          end)
      end

      it "sanitizes headers" do
        service.forward_webhook(
          webhook_body: webhook_body,
          source: "elevenlabs",
          headers: headers
        )

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            sanitized_headers = body.dig("llm_request_log", "raw_request", "headers")
            expect(sanitized_headers["content-type"]).to eq("application/json")
            expect(sanitized_headers["x-signature"]).to eq("[REDACTED]")
            expect(sanitized_headers["authorization"]).to eq("[REDACTED]")
          end)
      end
    end

    context "when validating parameters" do
      context "when webhook_body is missing" do
        context "when in silent mode" do
          it "logs warning and returns false" do
            expect do
              result = service.forward_webhook(webhook_body: nil, source: "elevenlabs")
              expect(result).to be_falsy
            end.to output(/COOLHAND WARNING.*webhook_body/).to_stdout
          end
        end

        context "when in non-silent mode" do
          let(:verbose_config) do
            instance_double(Coolhand::Configuration,
              api_key: "test-api-key",
              base_url: "https://coolhandlabs.com/api",
              silent: false)
          end

          before do
            allow(Coolhand).to receive(:configuration).and_return(verbose_config)
          end

          it "raises ArgumentError" do
            expect do
              service.forward_webhook(webhook_body: nil, source: "elevenlabs")
            end.to raise_error(ArgumentError, /webhook_body is required/)
          end
        end
      end

      context "when source is missing" do
        context "when in silent mode" do
          it "logs warning and returns false" do
            expect do
              result = service.forward_webhook(webhook_body: webhook_body, source: nil)
              expect(result).to be_falsy
            end.to output(/COOLHAND WARNING.*source/).to_stdout
          end
        end

        context "when in non-silent mode" do
          let(:verbose_config) do
            instance_double(Coolhand::Configuration,
              api_key: "test-api-key",
              base_url: "https://coolhandlabs.com/api",
              silent: false)
          end

          before do
            allow(Coolhand).to receive(:configuration).and_return(verbose_config)
          end

          it "raises ArgumentError" do
            expect do
              service.forward_webhook(webhook_body: webhook_body, source: "")
            end.to raise_error(ArgumentError, /source is required/)
          end
        end
      end

      context "when webhook_body is empty" do
        it "raises ArgumentError in non-silent mode" do
          verbose_config = instance_double(Coolhand::Configuration,
            api_key: "test-api-key",
            base_url: "https://coolhandlabs.com/api",
            silent: false)
          allow(Coolhand).to receive(:configuration).and_return(verbose_config)

          expect do
            service.forward_webhook(webhook_body: {}, source: "elevenlabs")
          end.to raise_error(ArgumentError, /webhook_body is required/)
        end
      end
    end
  end

  describe "private methods" do
    let(:service_with_private) do
      service = described_class.new
      service.extend(Module.new do
        def build_webhook_url_public(source, event_type)
          build_webhook_url(source, event_type)
        end

        def sanitize_headers_public(headers)
          sanitize_headers(headers)
        end

        def clean_webhook_body_public(body, source)
          clean_webhook_body(body, source)
        end
      end)
      service
    end

    describe "#build_webhook_url" do
      it "builds URL with event type" do
        url = service_with_private.build_webhook_url_public("elevenlabs", "post_call_transcription")
        expect(url).to eq("webhook://elevenlabs/post_call_transcription")
      end

      it "builds URL without event type" do
        url = service_with_private.build_webhook_url_public("elevenlabs", nil)
        expect(url).to eq("webhook://elevenlabs")
      end
    end

    describe "#sanitize_headers" do
      it "handles empty headers" do
        result = service_with_private.sanitize_headers_public({})
        expect(result).to eq({})
      end

      it "handles Rails ActionDispatch headers" do
        # Mock Rails headers object that doesn't respond to empty?
        rails_headers = instance_double("ActionDispatch::Http::Headers")
        # rubocop:enable RSpec/VerifiedDoubleReference
        allow(rails_headers).to receive(:respond_to?).with(:empty?).and_return(false)
        allow(rails_headers).to receive(:respond_to?).with(:each).and_return(true)
        allow(rails_headers).to receive(:each).and_yield("HTTP_CONTENT_TYPE", "application/json")

        result = service_with_private.sanitize_headers_public(rails_headers)
        expect(result["content-type"]).to eq("application/json")
      end

      it "handles nil headers" do
        result = service_with_private.sanitize_headers_public(nil)
        expect(result).to eq({})
      end

      it "converts Rails HTTP_ headers" do
        headers = {
          "HTTP_CONTENT_TYPE" => "application/json",
          "HTTP_X_SIGNATURE" => "abc123"
        }
        result = service_with_private.sanitize_headers_public(headers)
        expect(result["content-type"]).to eq("application/json")
        expect(result["x-signature"]).to eq("[REDACTED]")
      end

      it "redacts sensitive headers" do
        headers = {
          "HTTP_AUTHORIZATION" => "Bearer secret",
          "HTTP_X_API_KEY" => "secret_key",
          "HTTP_SECRET" => "secret_value",
          "HTTP_TOKEN" => "token_value",
          "HTTP_CONTENT_TYPE" => "application/json"
        }
        result = service_with_private.sanitize_headers_public(headers)
        expect(result["authorization"]).to eq("[REDACTED]")
        expect(result["x-api-key"]).to eq("[REDACTED]")
        expect(result["secret"]).to eq("[REDACTED]")
        expect(result["token"]).to eq("[REDACTED]")
        expect(result["content-type"]).to eq("application/json")
      end
    end

    describe "#clean_webhook_body" do
      context "when using elevenlabs source" do
        let(:elevenlabs_data) do
          {
            "type" => "post_call_transcription",
            "data" => {
              "conversation_id" => "conv_123",
              "transcript" => [
                { "role" => "user", "message" => "Hello" }
              ],
              "full_audio" => "base64audiodata",
              "audio_data" => "more_audio",
              "voice_sample" => "voice_data",
              "regular_field" => "keep_this"
            }
          }
        end

        it "filters out audio-related fields" do
          result = service_with_private.clean_webhook_body_public(elevenlabs_data, "elevenlabs")
          expect(result.dig("data", "full_audio")).to be_nil
          expect(result.dig("data", "audio_data")).to be_nil
          expect(result.dig("data", "voice_sample")).to be_nil
          expect(result.dig("data", "regular_field")).to eq("keep_this")
          expect(result.dig("data", "transcript")).not_to be_nil
        end
      end

      context "when using twilio source" do
        let(:twilio_data) do
          {
            "CallSid" => "CA123",
            "recording_url" => "https://example.com/recording.mp3",
            "media_url" => "https://example.com/media.mp3",
            "CallStatus" => "completed"
          }
        end

        it "filters out recording-related fields" do
          result = service_with_private.clean_webhook_body_public(twilio_data, "twilio")
          expect(result["recording_url"]).to be_nil
          expect(result["media_url"]).to be_nil
          expect(result["CallSid"]).to eq("CA123")
          expect(result["CallStatus"]).to eq("completed")
        end
      end

      context "when using unknown source" do
        let(:generic_data) do
          {
            "text_field" => "keep_this",
            "audio_data" => "remove_this",
            "image_data" => "remove_this_too",
            "normal_data" => "keep_this_too"
          }
        end

        it "filters out generic binary fields" do
          result = service_with_private.clean_webhook_body_public(generic_data, "unknown")
          expect(result["audio_data"]).to be_nil
          expect(result["image_data"]).to be_nil
          expect(result["text_field"]).to eq("keep_this")
          expect(result["normal_data"]).to eq("keep_this_too")
        end
      end

      context "with nested data structures" do
        let(:nested_data) do
          {
            "level1" => {
              "level2" => {
                "full_audio" => "remove_this",
                "keep_field" => "keep_this"
              },
              "array_data" => [
                { "audio_data" => "remove_this", "text" => "keep_this" }
              ]
            }
          }
        end

        it "recursively filters nested structures" do
          result = service_with_private.clean_webhook_body_public(nested_data, "elevenlabs")
          expect(result.dig("level1", "level2", "full_audio")).to be_nil
          expect(result.dig("level1", "level2", "keep_field")).to eq("keep_this")
          expect(result.dig("level1", "array_data", 0, "audio_data")).to be_nil
          expect(result.dig("level1", "array_data", 0, "text")).to eq("keep_this")
        end
      end
    end
  end
end
