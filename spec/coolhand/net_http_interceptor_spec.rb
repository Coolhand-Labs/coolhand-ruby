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

  describe ".patch!" do
    it "is idempotent and prepends module to Net::HTTP ancestors" do
      # Call patch! multiple times to ensure no errors and presence in ancestor chain
      expect { described_class.patch! }.not_to raise_error
      expect { described_class.patch! }.not_to raise_error

      expect(Net::HTTP.ancestors).to include(described_class)
    end
  end
end
