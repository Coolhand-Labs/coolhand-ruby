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

    it "fails closed to an empty hash, instead of raising, when a header-like object's own to_hash raises" do
      headers = Object.new
      def headers.to_hash
        raise "boom"
      end

      expect(described_class.sanitize_headers(headers)).to eq({})
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

    it "redacts embedded userinfo credentials even when the URL has no query string" do
      sanitized = described_class.sanitize_url("https://user:s3cr3t@my-llm-proxy.internal/v1/chat")

      expect(sanitized).not_to include("s3cr3t")
      expect(sanitized).to include("REDACTED@my-llm-proxy.internal")
    end

    it "redacts both embedded userinfo credentials and sensitive query params on the same URL" do
      sanitized = described_class.sanitize_url("https://user:s3cr3t@my-llm-proxy.internal/v1/chat?token=abc123")

      expect(sanitized).not_to include("s3cr3t")
      expect(sanitized).not_to include("abc123")
    end
  end

  describe ".sanitize_body" do
    it "redacts an Azure OpenAI On Your Data api_key credential under data_sources" do
      body = {
        "messages" => [{ "role" => "user", "content" => "hi" }],
        "data_sources" => [
          { "type" => "azure_search",
            "parameters" => { "authentication" => { "type" => "api_key", "key" => "top-secret-admin-key" } } }
        ]
      }

      sanitized = described_class.sanitize_body(body)
      auth = sanitized["data_sources"][0]["parameters"]["authentication"]

      expect(auth["key"]).to eq("[REDACTED]")
      expect(auth["type"]).to eq("api_key")
      expect(sanitized["data_sources"][0]["type"]).to eq("azure_search")
    end

    it "redacts under the camelCase dataSources spelling too" do
      body = { "dataSources" => [{ "parameters" => { "authentication" => { "key" => "secret" } } }] }

      sanitized = described_class.sanitize_body(body)

      expect(sanitized["dataSources"][0]["parameters"]["authentication"]["key"]).to eq("[REDACTED]")
    end

    it "redacts connection_string and connectionString regardless of separator style" do
      body = {
        "data_sources" => [
          { "parameters" => { "connection_string" => "AccountEndpoint=...;AccountKey=deadbeef" } },
          { "parameters" => { "connectionString" => "AccountEndpoint=...;AccountKey=deadbeef" } }
        ]
      }

      sanitized = described_class.sanitize_body(body)

      expect(sanitized["data_sources"][0]["parameters"]["connection_string"]).to eq("[REDACTED]")
      expect(sanitized["data_sources"][1]["parameters"]["connectionString"]).to eq("[REDACTED]")
    end

    it "redacts encoded_api_key by substring, not just an exact api_key match" do
      body = { "data_sources" => [{ "parameters" => { "encoded_api_key" => "es-live-key-abc123" } }] }

      sanitized = described_class.sanitize_body(body)

      expect(sanitized["data_sources"][0]["parameters"]["encoded_api_key"]).to eq("[REDACTED]")
    end

    it "leaves message content and tool schemas outside data_sources untouched" do
      body = {
        "messages" => [{ "role" => "user", "content" => "my api key is not a secret to redact" }],
        "tools" => [{ "type" => "function", "function" => { "name" => "my_secret_tool" } }],
        "data_sources" => [{ "parameters" => { "key" => "redact-me" } }]
      }

      sanitized = described_class.sanitize_body(body)

      expect(sanitized["messages"]).to eq(body["messages"])
      expect(sanitized["tools"]).to eq(body["tools"])
      expect(sanitized["data_sources"][0]["parameters"]["key"]).to eq("[REDACTED]")
    end

    it "passes non-Hash bodies through unchanged" do
      expect(described_class.sanitize_body(nil)).to be_nil
      expect(described_class.sanitize_body("raw string body")).to eq("raw string body")
    end

    it "passes a body with no data_sources/dataSources key through unchanged" do
      body = { "messages" => [{ "role" => "user", "content" => "hi" }] }

      expect(described_class.sanitize_body(body)).to eq(body)
    end
  end
end
