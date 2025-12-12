# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "webmock/rspec"

RSpec.describe Coolhand::Ruby::NetHttpInterceptor do
  let(:logger_service) { instance_double(Coolhand::Ruby::LoggerService) }
  let(:configuration) { instance_double(Coolhand::Configuration, patch_net_http: true, intercept_addresses: ["api.anthropic.com", "api.openai.com"]) }

  before do
    allow(Coolhand).to receive_messages(configuration: configuration, logger_service: logger_service)
    allow(Coolhand).to receive(:log)

    # Reset patching state
    described_class.instance_variable_set(:@patched, false)

    # Clear any existing patches
    if described_class >= Net::HTTP
      # Cannot easily unpatch prepend, so we'll work around it in tests
    end
  end

  describe ".patch!" do
    context "when patch_net_http is true" do
      it "patches Net::HTTP" do
        expect { described_class.patch! }.to change(described_class, :patched?).from(false).to(true)
      end

      it "logs the patching" do
        expect(Coolhand).to receive(:log).with("🔗 Net::HTTP interceptor patched")
        described_class.patch!
      end

      it "does not patch twice" do
        described_class.patch!
        expect(Coolhand).not_to receive(:log)
        described_class.patch!
      end
    end

    context "when patch_net_http is false" do
      before { allow(configuration).to receive(:patch_net_http).and_return(false) }

      it "does not patch Net::HTTP" do
        expect { described_class.patch! }.not_to(change(described_class, :patched?))
      end
    end
  end

  describe "#request" do
    let(:uri) { URI("https://api.anthropic.com/v1/messages") }
    let(:http) { Net::HTTP.new(uri.host, uri.port) }
    let(:request) { Net::HTTP::Post.new(uri) }
    let(:response) { Net::HTTPSuccess.new("1.1", "200", "OK") }
    let(:request_body) { '{"model": "claude-3-haiku", "messages": []}' }

    before do
      http.use_ssl = true

      # Stub the original request method to avoid actual HTTP calls
      allow(http).to receive(:request_without_coolhand_interceptor).and_return(response)

      # Apply the interceptor
      described_class.patch!
      http.extend(described_class)

      # Setup request
      request.body = request_body
      request["Content-Type"] = "application/json"
      request["X-API-Key"] = "test-key-123"

      # Setup response headers
      allow(response).to receive(:each_header).and_yield("content-type", "application/json").and_yield("request-id",
        "req_12345")
      allow(response).to receive(:[]).with("request-id").and_return("req_12345")

      # Mock logger service calls
      allow(logger_service).to receive(:log_to_api)
    end

    context "when intercepting requests to monitored addresses" do
      it "intercepts the request" do
        expect(Coolhand).to receive(:log).with(match(/🌐 Intercepting Net::HTTP request/))
        http.request(request, request_body)
      end

      it "sends request metadata to Coolhand" do
        expect(logger_service).to receive(:log_to_api) do |data|
          expect(data[:phase]).to eq("request")
          expect(data[:method]).to eq(:post)
          expect(data[:url]).to eq("https://api.anthropic.com/v1/messages")
          expect(data[:headers]).to include("x-api-key" => "[REDACTED]")
          expect(data[:headers]).to include("content-type" => "application/json")
        end

        http.request(request, request_body)
      end

      it "sends response metadata to Coolhand" do
        expect(logger_service).to receive(:log_to_api) do |data|
          expect(data[:phase]).to eq("response_metadata")
          expect(data[:status_code]).to eq(200)
          expect(data[:correlation_id]).to eq("req_12345")
          expect(data[:response_headers]).to include("request-id" => "req_12345")
        end

        http.request(request, request_body)
      end

      it "redacts sensitive headers" do
        request["Authorization"] = "Bearer secret-token"
        request["X-Secret-Key"] = "very-secret"

        expect(logger_service).to receive(:log_to_api) do |data|
          expect(data[:headers]["authorization"]).to eq("[REDACTED]")
          expect(data[:headers]["x-secret-key"]).to eq("[REDACTED]")
        end

        http.request(request, request_body)
      end

      it "captures timing information" do
        expect(logger_service).to receive(:log_to_api) do |data|
          expect(data[:duration_ms]).to be_a(Numeric)
          expect(data[:duration_ms]).to be > 0
        end

        http.request(request, request_body)
      end

      it "returns the original response" do
        result = http.request(request, request_body)
        expect(result).to eq(response)
      end
    end

    context "when intercepting requests to non-monitored addresses" do
      let(:uri) { URI("https://example.com/api") }
      let(:http) { Net::HTTP.new(uri.host, uri.port) }

      it "does not intercept the request" do
        expect(Coolhand).not_to receive(:log).with(match(/🌐 Intercepting/))
        expect(logger_service).not_to receive(:log_to_api)

        http.request(request, request_body)
      end
    end

    context "when an error occurs" do
      before do
        allow(http).to receive(:request_without_coolhand_interceptor).and_raise(StandardError.new("Connection failed"))
      end

      it "logs error metadata" do
        expect(logger_service).to receive(:log_to_api) do |data|
          expect(data[:phase]).to eq("error")
          expect(data[:status_code]).to eq(500)
          expect(data[:error]).to eq("Connection failed")
        end

        expect { http.request(request, request_body) }.to raise_error(StandardError, "Connection failed")
      end

      it "extracts correlation ID from error message if available" do
        error_message = 'API Error: request_id: "req_error_123"'
        allow(http).to receive(:request_without_coolhand_interceptor).and_raise(StandardError.new(error_message))

        expect(logger_service).to receive(:log_to_api) do |data|
          expect(data[:correlation_id]).to eq("req_error_123")
        end

        expect { http.request(request, request_body) }.to raise_error(StandardError)
      end
    end
  end

  describe "private methods" do
    let(:interceptor_instance) do
      obj = Object.new
      obj.extend(described_class)
      obj
    end

    describe "#should_intercept_request?" do
      let(:request) { Net::HTTP::Post.new("/v1/messages") }

      before do
        # Mock the interceptor instance methods
        allow(interceptor_instance).to receive_messages(use_ssl?: true, address: "api.anthropic.com", port: 443)
      end

      it "returns true for monitored addresses" do
        result = interceptor_instance.send(:should_intercept_request?, request)
        expect(result).to be true
      end

      it "returns false for non-monitored addresses" do
        allow(interceptor_instance).to receive(:address).and_return("example.com")
        result = interceptor_instance.send(:should_intercept_request?, request)
        expect(result).to be false
      end
    end

    describe "#extract_headers" do
      let(:request) { Net::HTTP::Post.new("/test") }

      before do
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer secret"
        request["X-API-Key"] = "secret-key"
        request["User-Agent"] = "MyApp/1.0"
      end

      it "redacts sensitive headers" do
        headers = interceptor_instance.send(:extract_headers, request)

        expect(headers["content-type"]).to eq("application/json")
        expect(headers["user-agent"]).to eq("MyApp/1.0")
        expect(headers["authorization"]).to eq("[REDACTED]")
        expect(headers["x-api-key"]).to eq("[REDACTED]")
      end
    end

    describe "#generate_request_id" do
      it "generates a unique request ID" do
        id1 = interceptor_instance.send(:generate_request_id)
        id2 = interceptor_instance.send(:generate_request_id)

        expect(id1).to match(/^req_[a-f0-9]{16}$/)
        expect(id2).to match(/^req_[a-f0-9]{16}$/)
        expect(id1).not_to eq(id2)
      end
    end
  end

  describe "integration with background logging" do
    let(:uri) { URI("https://api.anthropic.com/v1/messages") }
    let(:http) { Net::HTTP.new(uri.host, uri.port) }
    let(:request) { Net::HTTP::Post.new(uri) }
    let(:response) { Net::HTTPSuccess.new("1.1", "200", "OK") }

    before do
      described_class.patch!
      http.extend(described_class)
      http.use_ssl = true

      allow(http).to receive(:request_without_coolhand_interceptor).and_return(response)
      allow(response).to receive(:each_header).and_yield("request-id", "req_12345")
      allow(response).to receive(:[]).with("request-id").and_return("req_12345")
    end

    it "logs in background threads" do
      # Mock Thread.new to capture the block but execute it immediately
      allow(Thread).to receive(:new) do |&block|
        block.call
        instance_double(Thread)
      end

      expect(logger_service).to receive(:log_to_api).twice # request + response metadata

      http.request(request)
    end

    it "handles logging failures gracefully" do
      allow(logger_service).to receive(:log_to_api).and_raise(StandardError.new("Logging failed"))

      expect(Coolhand).to receive(:log).with(match(/❌ Failed to send.*metadata/))

      expect { http.request(request) }.not_to raise_error
    end
  end
end
