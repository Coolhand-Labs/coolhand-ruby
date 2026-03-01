# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::ApiService do
  before do
    allow(Coolhand).to receive(:log)
    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
    end
  end

  describe "debug_mode with send_llm_request_log" do
    let(:service) { described_class.new }
    let(:request_data) do
      {
        raw_request: {
          method: "POST",
          url: "https://api.openai.com/v1/chat/completions",
          request_body: { model: "gpt-4" },
          response_body: { choices: [] },
          status_code: 200
        }
      }
    end

    context "when debug_mode is false (default)" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })
      end

      it "sends request to API" do
        service.send_llm_request_log(request_data)
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end
    end

    context "when debug_mode is true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "does not send request to API" do
        result = service.send_llm_request_log(request_data)
        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end

      it "logs payload locally" do
        Coolhand.configuration.silent = false
        expect { service.send_llm_request_log(request_data) }.to output(/Debug Mode/).to_stdout
      end
    end
  end

  describe "debug_mode with create_feedback" do
    let(:service) { Coolhand::FeedbackService.new }
    let(:feedback) do
      {
        llm_request_log_id: 456,
        like: true,
        explanation: "Great response!"
      }
    end

    context "when debug_mode is false" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })
      end

      it "sends request to API" do
        service.create_feedback(feedback)
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
      end
    end

    context "when debug_mode is true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "does not send request to API" do
        result = service.create_feedback(feedback)
        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
      end
    end
  end

  describe "debug_mode with create_log" do
    let(:service) { Coolhand::LoggerService.new }
    let(:captured_data) do
      {
        method: "POST",
        url: "https://api.openai.com/v1/chat/completions",
        request_body: { model: "gpt-4" },
        response_body: { choices: [] },
        status_code: 200
      }
    end

    context "when debug_mode is false" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })
      end

      it "sends request to API" do
        service.log_to_api(captured_data)
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end
    end

    context "when debug_mode is true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "does not send request to API" do
        result = service.log_to_api(captured_data)
        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end
    end
  end
end
