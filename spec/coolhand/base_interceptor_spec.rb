# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::BaseInterceptor do
  before do
    Coolhand.configuration.silent = true
  end

  describe ".send_complete_request_log" do
    let(:start_time) { Time.iso8601("2026-01-04T20:16:56Z") }
    let(:end_time) { Time.iso8601("2026-01-04T20:16:57Z") }
    let(:base_args) do
      {
        request_id: "req-1",
        method: "POST",
        url: "https://api.example.com/v1/things",
        request_headers: {},
        request_body: { "input" => "foo" },
        response_headers: {},
        response_body: { "output" => "bar" },
        status_code: 200,
        start_time: start_time,
        end_time: end_time,
        duration_ms: 1000,
        is_streaming: false
      }
    end

    it "includes source_api and model when both are present" do
      api_service = instance_double(Coolhand::ApiService)
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

      expect(api_service).to receive(:send_llm_request_log).with(
        hash_including(raw_request: hash_including(source_api: "vertex", model: "gemini-2.0-flash"))
      )

      described_class.send_complete_request_log(**base_args, source_api: "vertex", model: "gemini-2.0-flash")
    end

    it "omits source_api and model entirely when both are blank or absent" do
      api_service = instance_double(Coolhand::ApiService)
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

      expect(api_service).to receive(:send_llm_request_log).with(
        hash_including(raw_request: hash_excluding(:source_api, :model))
      )

      described_class.send_complete_request_log(**base_args, source_api: "   ", model: nil)
    end

    it "sanitizes sensitive query parameters in the url" do
      api_service = instance_double(Coolhand::ApiService)
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

      expect(api_service).to receive(:send_llm_request_log).with(
        hash_including(
          raw_request: hash_including(url: "https://api.example.com/v1/things?key=%5BREDACTED%5D")
        )
      )

      described_class.send_complete_request_log(**base_args, url: "https://api.example.com/v1/things?key=secret")
    end

    it "sanitizes sensitive request and response headers, even for a caller that didn't pre-sanitize" do
      api_service = instance_double(Coolhand::ApiService)
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

      expect(api_service).to receive(:send_llm_request_log).with(
        hash_including(
          raw_request: hash_including(
            headers: { "Authorization" => "[REDACTED]" },
            response_headers: { "X-Api-Key" => "[REDACTED]" }
          )
        )
      )

      described_class.send_complete_request_log(
        **base_args,
        request_headers: { "Authorization" => "some-token" },
        response_headers: { "X-Api-Key" => "some-key" }
      )
    end

    it "rescues and swallows an error from the API service without raising" do
      api_service = instance_double(Coolhand::ApiService)
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
      allow(api_service).to receive(:send_llm_request_log).and_raise("network error")

      expect { described_class.send_complete_request_log(**base_args) }.not_to raise_error
    end
  end

  describe ".sanitize_headers" do
    it "redacts cookie and set-cookie headers, not just auth/key/token-shaped ones" do
      sanitized = described_class.sanitize_headers(
        "Cookie" => "_session=abc123; remember_token=deadbeef",
        "Set-Cookie" => "_session=xyz789; path=/",
        "Content-Type" => "application/json"
      )

      expect(sanitized["Cookie"]).to eq("[REDACTED]")
      expect(sanitized["Set-Cookie"]).to eq("[REDACTED]")
      expect(sanitized["Content-Type"]).to eq("application/json")
    end
  end

  describe ".sanitize_url" do
    it "redacts presigned-URL credential params for AWS SigV4 and Google Cloud storage URLs, " \
       "not just the small fixed list it used to check" do
      aws_url = described_class.sanitize_url(
        "https://bucket.s3.amazonaws.com/file?X-Amz-Signature=abc&X-Amz-Credential=AKIA%2Fx&" \
        "X-Amz-Security-Token=TOKENSECRET"
      )
      goog_url = described_class.sanitize_url(
        "https://storage.googleapis.com/file?X-Goog-Signature=deadbeef&X-Goog-Credential=svc%40proj"
      )
      misc_url = described_class.sanitize_url("https://example.com?sig=abc&password=p&auth=ghi&safe=1")

      expect(aws_url).not_to include("abc")
      expect(aws_url).not_to include("AKIA")
      expect(aws_url).not_to include("TOKENSECRET")
      expect(goog_url).not_to include("deadbeef")
      expect(goog_url).not_to include("svc%40proj")
      expect(misc_url).to include("safe=1")
      expect(misc_url).not_to include("=abc")
      expect(misc_url).not_to include("=p&")
      expect(misc_url).not_to include("=ghi")
    end
  end
end
