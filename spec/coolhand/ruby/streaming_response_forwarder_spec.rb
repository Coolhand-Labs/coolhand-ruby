# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Ruby::StreamingResponseForwarder do
  let(:llm_responses_service) { instance_double(Coolhand::Ruby::LlmResponsesService) }
  let(:forwarder) { described_class.new(llm_responses_service) }

  before do
    allow(Coolhand).to receive(:log)
  end

  describe "#initialize" do
    context "with llm_responses_service provided" do
      it "uses the provided LLM responses service" do
        expect(forwarder.instance_variable_get(:@llm_responses_service)).to eq(llm_responses_service)
      end
    end

    context "without llm_responses_service provided" do
      let(:default_service) { instance_double(Coolhand::Ruby::LlmResponsesService) }

      before do
        allow(Coolhand).to receive(:llm_responses_service).and_return(default_service)
      end

      it "uses the default Coolhand LLM responses service" do
        forwarder = described_class.new
        expect(forwarder.instance_variable_get(:@llm_responses_service)).to eq(default_service)
      end
    end
  end

  describe "#forward_response" do
    let(:request_data) do
      {
        model: "claude-3-haiku-20240307",
        messages: [{ role: "user", content: "Hello" }],
        max_tokens: 100
      }
    end
    let(:correlation_id) { "req_test_123" }

    before do
      allow(llm_responses_service).to receive(:log_streaming_response)
      allow(Thread).to receive(:new).and_yield # Execute thread block immediately for testing
    end

    context "with Anthropic-style response object" do
      let(:content_item) { double("content", to_h: { type: "text", text: "Hello world" }) }
      let(:usage) { double("usage", to_h: { input_tokens: 10, output_tokens: 5 }) }
      let(:response) do
        double("anthropic_response",
          id: "resp_123",
          type: "message",
          role: "assistant",
          model: "claude-3-haiku",
          content: [content_item],
          stop_reason: "end_turn",
          stop_sequence: nil,
          usage: usage,
          respond_to?: true)
      end

      before do
        allow(response).to receive(:respond_to?).with(:content).and_return(true)
        allow(response).to receive(:respond_to?).with(:usage).and_return(true)
        allow(response).to receive(:respond_to?).with(:to_h).and_return(false)
        allow(response).to receive(:respond_to?).with(:id).and_return(true)
        allow(response).to receive(:respond_to?).with(:type).and_return(true)
        allow(response).to receive(:respond_to?).with(:role).and_return(true)
        allow(response).to receive(:respond_to?).with(:model).and_return(true)
        allow(response).to receive(:respond_to?).with(:stop_reason).and_return(true)
        allow(response).to receive(:respond_to?).with(:stop_sequence).and_return(true)
        allow(response).to receive(:respond_to?).with(:headers).and_return(false)
        allow(response.content).to receive(:respond_to?).with(:map).and_return(true)
        allow(response.usage).to receive(:respond_to?).with(:to_h).and_return(true)
      end

      it "forwards the response with structured data" do
        expect(llm_responses_service).to receive(:log_streaming_response) do |data|
          expect(data[:response_body]).to include(
            id: "resp_123",
            type: "message",
            role: "assistant",
            model: "claude-3-haiku",
            content: [{ type: "text", text: "Hello world" }],
            stop_reason: "end_turn",
            usage: { input_tokens: 10, output_tokens: 5 }
          )
          expect(data[:response_headers]).to eq({})
        end

        forwarder.forward_response(request_data, response)
      end

      it "logs success message" do
        expect(Coolhand).to receive(:log).with("✅ Sent streaming response to Coolhand LLM endpoint (correlation_id: resp_123)")
        forwarder.forward_response(request_data, response)
      end
    end

    context "with response object that has to_h method" do
      let(:response) do
        double("structured_response",
          to_h: { id: "resp_456", content: "Hello", usage: { tokens: 15 } },
          id: "resp_456")
      end

      before do
        allow(response).to receive(:respond_to?).with(:to_h).and_return(true)
        allow(response).to receive(:respond_to?).with(:id).and_return(true)
        allow(response).to receive(:respond_to?).with(:headers).and_return(false)
        allow(response).to receive(:respond_to?).with(:[]).and_return(false)
      end

      it "uses the to_h method to serialize response" do
        expect(llm_responses_service).to receive(:log_streaming_response) do |data|
          expect(data[:response_body]).to eq(id: "resp_456", content: "Hello", usage: { tokens: 15 })
          expect(data[:response_headers]).to eq({})
        end

        forwarder.forward_response(request_data, response)
      end
    end

    context "with hash response" do
      let(:response) { { "id" => "resp_789", "content" => "Hello", "usage" => { "tokens" => 20 } } }

      it "uses the hash directly" do
        expect(llm_responses_service).to receive(:log_streaming_response) do |data|
          expect(data[:response_body]).to eq(response)
          expect(data[:response_headers]).to eq({})
        end

        forwarder.forward_response(request_data, response)
      end
    end

    context "with string response" do
      let(:response) { "Plain text response" }

      it "uses the string as response body" do
        expect(llm_responses_service).to receive(:log_streaming_response) do |data|
          expect(data[:response_body]).to eq("Plain text response")
          expect(data[:response_headers]).to eq({})
        end

        forwarder.forward_response(request_data, response)
      end
    end

    context "with custom correlation_id" do
      let(:response) { { "id" => "resp_auto", "content" => "Hello" } }
      let(:custom_correlation_id) { "custom_req_123" }

      it "uses the provided correlation_id" do
        expect(llm_responses_service).to receive(:log_streaming_response) do |data|
          expect(data[:response_body]).to eq(response)
          expect(data[:response_headers]).to eq({})
        end

        forwarder.forward_response(request_data, response, correlation_id: custom_correlation_id)
      end
    end


    context "when logging fails" do
      let(:test_response) { { "id" => "test_123" } }

      before do
        allow(llm_responses_service).to receive(:log_streaming_response).and_raise(StandardError.new("Network error"))
      end

      it "logs the error" do
        expect(Coolhand).to receive(:log).with("❌ Failed to send streaming response to Coolhand: Network error")
        forwarder.forward_response(request_data, test_response)
      end

      it "does not raise the error" do
        expect { forwarder.forward_response(request_data, test_response) }.not_to raise_error
      end
    end

  end

  describe "private methods" do
    describe "#extract_correlation_id" do
      it "extracts from object with id method" do
        response = double("response", id: "resp_123")
        allow(response).to receive(:respond_to?).with(:id).and_return(true)

        correlation_id = forwarder.send(:extract_correlation_id, response)
        expect(correlation_id).to eq("resp_123")
      end

      it "extracts from hash with string key" do
        response = { "id" => "resp_456" }

        correlation_id = forwarder.send(:extract_correlation_id, response)
        expect(correlation_id).to eq("resp_456")
      end

      it "extracts from hash with symbol key" do
        response = { id: "resp_789" }

        correlation_id = forwarder.send(:extract_correlation_id, response)
        expect(correlation_id).to eq("resp_789")
      end

      it "generates unknown ID for objects without extractable ID" do
        response = "plain string"

        correlation_id = forwarder.send(:extract_correlation_id, response)
        expect(correlation_id).to match(/^unknown_[a-f0-9]{8}$/)
      end
    end

    describe "#build_raw_request" do
      let(:request_data) { { model: "test", messages: [] } }
      let(:response) { { "id" => "resp_test" } }
      let(:correlation_id) { "corr_123" }

      it "builds raw request structure with response body and headers" do
        data = forwarder.send(:build_raw_request, request_data, response, correlation_id)

        expect(data).to include(
          response_body: response,
          response_headers: {}
        )
      end
    end
  end

  describe "integration with main Coolhand module" do
    let(:request_data) { { model: "claude-3-haiku", messages: [] } }
    let(:response) { { "id" => "resp_integration", "content" => "test" } }

    before do
      allow(Coolhand).to receive(:streaming_response_forwarder).and_return(forwarder)
      allow(Thread).to receive(:new).and_yield
      allow(llm_responses_service).to receive(:log_streaming_response)
    end

    describe "forward_streaming_response" do
      it "calls the forwarder service" do
        expect(forwarder).to receive(:forward_response).with(
          request_data,
          response,
          correlation_id: nil
        )

        Coolhand.forward_streaming_response(request_data, response)
      end
    end
  end

  describe "error handling edge cases" do
    let(:request_data) { {} }

    before do
      allow(Thread).to receive(:new).and_yield
      allow(llm_responses_service).to receive(:log_streaming_response)
    end

    context "with nil response" do
      it "handles nil response gracefully" do
        expect { forwarder.forward_response(request_data, nil) }.not_to raise_error

        expect(llm_responses_service).to have_received(:log_streaming_response) do |data|
          expect(data[:response_body]).to eq(nil)
        end
      end
    end

    context "with response that raises errors on method calls" do
      let(:problematic_response) do
        response = double("problematic_response")
        allow(response).to receive(:respond_to?).and_return(false)
        allow(response).to receive(:respond_to?).with(:id).and_return(true)
        allow(response).to receive(:id).and_raise(StandardError.new("ID access failed"))
        response
      end

      it "handles method access errors gracefully" do
        # Should fall back to unknown correlation ID generation
        expect { forwarder.forward_response(request_data, problematic_response) }.not_to raise_error
      end
    end
  end
end
