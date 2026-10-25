# frozen_string_literal: true

require "webmock/rspec"
require "json"

# Shared by the batch-processor specs that assert on what actually reaches the wire, i.e. the
# HTTP request the real ApiService sends to Coolhand, rather than on what is handed to a stubbed
# ApiService. Including specs must define `let(:secret)`, a string that must never appear in
# anything sent.
module LogWireHelper
  LOG_ENDPOINT = "https://coolhandlabs.com/api/v2/llm_request_logs"
  WIRE_API_KEY = "test-key"

  # Configures Coolhand (API key, silent) and stubs its log endpoint, recording every request it
  # receives.
  def stub_log_endpoint
    Coolhand.configuration.api_key = WIRE_API_KEY
    Coolhand.configuration.silent = true
    @wire_requests = []
    stub_request(:post, LOG_ENDPOINT).to_return do |request|
      @wire_requests << request
      { status: 200, body: { id: 1 }.to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  def wire_requests
    @wire_requests ||= []
  end

  def wire_raw_requests
    wire_requests.map { |request| JSON.parse(request.body).fetch("llm_request_log").fetch("raw_request") }
  end
end

RSpec.shared_examples "a log request sent to the Coolhand API" do
  it "authenticates with the configured API key and sends JSON" do
    expect(wire_requests).not_to be_empty
    expect(wire_requests).to all(satisfy { |r| r.headers["X-Api-Key"] == LogWireHelper::WIRE_API_KEY })
    expect(wire_requests).to all(satisfy { |r| r.headers["Content-Type"] == "application/json" })
  end

  it "identifies the collector and sends no request or response headers" do
    wire_requests.each do |request|
      log = JSON.parse(request.body).fetch("llm_request_log")
      expect(log["collector"]).to be_a(String).and(satisfy { |c| !c.empty? })
      expect(log["raw_request"]).to include("headers" => {}, "response_headers" => {}, "is_streaming" => false)
    end
  end

  it "never puts a credential from the request body on the wire" do
    expect(wire_requests).not_to be_empty
    expect(wire_requests.map(&:body).join).not_to include(secret)
  end
end
