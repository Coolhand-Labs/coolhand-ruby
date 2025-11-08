# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::Ruby::LoggerService do
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-api-key",
      silent: true)
  end
  let(:service) { described_class.new }

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  describe "#initialize" do
    it "configures with the provided endpoint" do
      expect(service.api_endpoint).to eq("https://coolhand.io/api/v2/llm_request_logs")
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
        stub_request(:post, "https://coolhand.io/api/v2/llm_request_logs")
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

        expect(WebMock).to(have_requested(:post, "https://coolhand.io/api/v2/llm_request_logs")
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

        expect(WebMock).to(have_requested(:post, "https://coolhand.io/api/v2/llm_request_logs")
          .with do |req|
            body = JSON.parse(req.body)
            payload = body["llm_request_log"]

            # Check that collector field is present and has auto-monitor method
            expect(payload).to have_key("collector")
            expect(payload["collector"]).to eq("coolhand-ruby-#{Coolhand::Ruby::VERSION}-auto-monitor")
          end)
      end
    end

    context "when API call fails" do
      before do
        stub_request(:post, "https://coolhand.io/api/v2/llm_request_logs")
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "handles failed API response gracefully" do
        expect { service.log_to_api(captured_data) }.to output(/Request failed/).to_stdout
        result = service.log_to_api(captured_data)
        expect(result).to be_nil
      end
    end

    context "with logging behavior" do
      context "when in silent mode" do
        it "does not output logs" do
          stub_request(:post, "https://coolhand.io/api/v2/llm_request_logs")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { service.log_to_api(captured_data) }.not_to output(/LOGGING OpenAI/).to_stdout
        end
      end

      context "when not in silent mode" do
        let(:verbose_config) do
          instance_double(Coolhand::Configuration,
            api_key: "test-api-key",
            silent: false)
        end

        let(:verbose_service) do
          allow(Coolhand).to receive(:configuration).and_return(verbose_config)
          described_class.new
        end

        it "outputs verbose logs" do
          stub_request(:post, "https://coolhand.io/api/v2/llm_request_logs")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.log_to_api(captured_data) }
            .to output(/🎉 LOGGING OpenAI/).to_stdout
        end
      end
    end
  end
end
