# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"

RSpec.describe Coolhand::NetHttpInterceptor do
  let(:api_service_instance) { instance_double(Coolhand::ApiService) }
  let(:api_service_class) { class_double(Coolhand::ApiService).as_stubbed_const }

  before do
    allow(Coolhand).to receive(:log)

    # capture the argument passed to send_llm_request_log for easier assertions (handles streaming adapters)
    @captured_log = nil
    allow(api_service_class).to receive(:new).and_return(api_service_instance)
    allow(api_service_instance).to receive(:send_llm_request_log) do |arg|
      @captured_log = arg
    end

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["api.test.com"]
    end
  end

  it "intercepts a Net::HTTP request and logs the response body" do
    stub_request(:get, "https://api.test.com/hello")
      .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/hello")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri)

    http.request(req)

    # Allow any background thread (if used) to run
    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw).to be_a(Hash)
    expect(raw[:url] || raw["url"]).to eq("https://api.test.com/hello")
    expect((raw[:method] || raw["method"]).to_s).to match(/get/i)
    expect(raw[:response_body] || raw["response_body"]).to eq({ "msg" => "hi" })
    expect(raw[:status_code] || raw["status_code"]).to eq(200)
  end

  it "captures streaming responses via read_body and marks is_streaming" do
    stub_request(:get, "https://api.test.com/stream")
      .to_return(status: 200, body: "chunk1chunk2", headers: { "Content-Type" => "application/octet-stream" })

    uri = URI("https://api.test.com/stream")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri)

    # Use request with block and read_body to trigger streaming path
    http.request(req) do |res|
      res.read_body do |chunk|
        # consumer would process chunks here
      end
    end

    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw).to be_a(Hash)
    expect(raw[:url] || raw["url"]).to eq("https://api.test.com/stream")
    expect(raw[:is_streaming] || raw["is_streaming"]).to be true
    # Accept any non-nil response_body (string or streaming adapter)
    resp_body = raw[:response_body] || raw["response_body"]
    expect(resp_body).not_to be_nil
  end

  describe "capture control" do
    before(:each) do
      stub_request(:get, "https://api.test.com/hello")
        .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })
    end

    def make_request
      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      http.request(req)
      sleep 0.05
    end

    context "with default config (capture: true)" do
      it "captures requests by default" do
        make_request
        expect(@captured_log).to be_a(Hash)
      end

      it "does not capture inside without_capture block" do
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_nil
      end

      it "still captures inside with_capture block" do
        Coolhand.with_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end
    end

    context "with capture: false" do
      before do
        Coolhand.configuration.capture = false
      end

      it "does not capture requests by default" do
        make_request
        expect(@captured_log).to be_nil
      end

      it "captures inside with_capture block" do
        Coolhand.with_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end

      it "does not capture inside without_capture block" do
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_nil
      end
    end

    context "with debug_mode: true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "captures even inside without_capture block" do
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end

      it "captures when capture config is false" do
        Coolhand.configuration.capture = false
        make_request
        expect(@captured_log).to be_a(Hash)
      end

      it "captures when capture config is false AND inside without_capture" do
        Coolhand.configuration.capture = false
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end
    end
  end

  describe ".patch!" do
    it "is idempotent and prepends module to Net::HTTP ancestors" do
      # Call patch! multiple times to ensure no errors and presence in ancestor chain
      expect { described_class.patch! }.not_to raise_error
      expect { described_class.patch! }.not_to raise_error

      expect(Net::HTTP.ancestors).to include(described_class)
    end
  end

  it "still logs when the HTTP call raises an exception (e.g. SDK error on 4xx)" do
    stub_request(:post, "https://api.test.com/v1/messages")
      .to_return(
        status: 404,
        body: '{"type":"error","error":{"type":"not_found_error","message":"model: claude-3-7-sonnet-latest"}}',
        headers: { "Content-Type" => "application/json" }
      )

    uri = URI("https://api.test.com/v1/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body = '{"model":"claude-3-7-sonnet-latest"}'

    response = http.request(req)
    expect(response.code.to_i).to eq(404)

    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw[:status_code] || raw["status_code"]).to eq(404)
  end

  describe "exclude_api_patterns" do
    before(:each) do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = ["aiplatform.googleapis.com"]
      end
    end

    def make_request(path)
      stub_request(:get, "https://aiplatform.googleapis.com#{path}")
        .to_return(status: 200, body: '{"status":"ok"}', headers: { "Content-Type" => "application/json" })

      uri = URI("https://aiplatform.googleapis.com#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      http.request(req)
      sleep 0.05
    end

    it "does not capture URLs matching the default /batchPredictionJobs/ pattern" do
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
      expect(@captured_log).to be_nil
    end

    it "captures URLs that do not match any exclude pattern" do
      make_request("/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-pro:generateContent")
      expect(@captured_log).to be_a(Hash)
    end

    it "captures all URLs when exclude_api_patterns is set to empty" do
      Coolhand.configuration.exclude_api_patterns = []
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
      expect(@captured_log).to be_a(Hash)
    end

    it "excludes URLs matching a custom pattern appended with <<" do
      Coolhand.configuration.exclude_api_patterns << ":generateContent"
      make_request("/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-pro:generateContent")
      expect(@captured_log).to be_nil
    end

    it "excludes only patterns in the overridden list when using =" do
      Coolhand.configuration.exclude_api_patterns = ["/generateContent"]
      # batchPredictionJobs is no longer excluded
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
      expect(@captured_log).to be_a(Hash)
    end

    it "logs a debug message when a URL is excluded and debug_mode is enabled" do
      Coolhand.configuration.debug_mode = true
      expect(Coolhand).to receive(:log).with(/Skipping capture.*batchPredictionJobs/)
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
    end

    it "does not log a debug message for excluded URLs when debug_mode is disabled" do
      expect(Coolhand).not_to receive(:log).with(/Skipping capture/)
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
    end

    it "exposes DEFAULT_EXCLUDE_API_PATTERNS as a frozen constant" do
      defaults = Coolhand::Configuration::DEFAULT_EXCLUDE_API_PATTERNS
      expect(defaults).to include("/batchPredictionJobs/")
      expect(defaults).to be_frozen
    end

    it "initializes exclude_api_patterns as a mutable copy of the defaults" do
      patterns = Coolhand.configuration.exclude_api_patterns
      expect(patterns).to include("/batchPredictionJobs/")
      expect(patterns).not_to be_frozen
    end
  end

  it "logs with extracted status and SDK exception format when super itself raises" do
    stub_request(:post, "https://api.test.com/v1/messages")
      .to_raise(RuntimeError.new("status: 404, body: not_found_error"))

    uri = URI("https://api.test.com/v1/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body = '{"model":"claude-3-7-sonnet-latest"}'

    expect { http.request(req) }.to raise_error(RuntimeError)

    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw[:status_code] || raw["status_code"]).to eq(404)
    resp_body = raw[:response_body] || raw["response_body"]
    expect(resp_body).to be_a(Hash)
    error_info = resp_body["error"] || resp_body[:error]
    expect(error_info["class"]).to include("RuntimeError")
  end
end
