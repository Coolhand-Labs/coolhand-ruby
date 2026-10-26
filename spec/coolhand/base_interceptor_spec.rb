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

    let(:api_service) { instance_double(Coolhand::ApiService) }
    let(:sent) { [] }

    before do
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
      allow(api_service).to receive(:send_llm_request_log) { |arg| sent << arg }
    end

    def raw_request
      sent.first.fetch(:raw_request)
    end

    it "sends the full request/response payload, normalized and sanitized" do
      described_class.send_complete_request_log(**base_args, status_code: 201)

      expect(sent.size).to eq(1)
      expect(raw_request).to eq(
        id: "req-1",
        timestamp: "2026-01-04T20:16:56Z",
        method: "post",
        url: "https://api.example.com/v1/things",
        headers: {},
        request_body: { "input" => "foo" },
        response_headers: {},
        response_body: { "output" => "bar" },
        status_code: 201,
        duration_ms: 1000,
        completed_at: "2026-01-04T20:16:57Z",
        is_streaming: false
      )
    end

    it "includes source_api and model when both are present" do
      described_class.send_complete_request_log(**base_args, source_api: "vertex", model: "gemini-2.0-flash")

      expect(raw_request).to include(source_api: "vertex", model: "gemini-2.0-flash")
    end

    it "omits source_api and model entirely when both are blank or absent" do
      described_class.send_complete_request_log(**base_args, source_api: "   ", model: nil)

      expect(raw_request.keys).not_to include(:source_api, :model)
    end

    it "sanitizes sensitive query parameters in the url" do
      described_class.send_complete_request_log(**base_args, url: "https://api.example.com/v1/things?key=secret")

      expect(raw_request[:url]).to eq("https://api.example.com/v1/things?key=%5BREDACTED%5D")
    end

    it "sanitizes sensitive request and response headers, even for a caller that didn't pre-sanitize" do
      described_class.send_complete_request_log(
        **base_args,
        request_headers: { "Authorization" => "some-token", "Content-Type" => "application/json" },
        response_headers: { "X-Api-Key" => "some-key" }
      )

      expect(raw_request[:headers]).to eq("Authorization" => "[REDACTED]", "Content-Type" => "application/json")
      expect(raw_request[:response_headers]).to eq("X-Api-Key" => "[REDACTED]")
    end

    it "redacts Azure data_sources credentials in the request body that is sent" do
      body = { "data_sources" => [{ "parameters" => { "key" => "top-secret", "index_name" => "docs" } }] }

      described_class.send_complete_request_log(**base_args, request_body: body)

      expect(raw_request[:request_body]).to eq(
        "data_sources" => [{ "parameters" => { "key" => "[REDACTED]", "index_name" => "docs" } }]
      )
    end

    it "redacts credentials in the response body that is sent, not just the request body" do
      response = { "value" => "ek_live_abc", "expires_at" => 1_900_000_000, "session" => { "model" => "gpt-realtime" } }

      described_class.send_complete_request_log(
        **base_args,
        request_body: { "api_key" => "sk-request-secret", "input" => "foo" },
        response_body: response
      )

      expect(raw_request[:request_body]).to eq("api_key" => "[REDACTED]", "input" => "foo")
      expect(raw_request[:response_body]).to eq(
        "value" => "[REDACTED]", "expires_at" => 1_900_000_000, "session" => { "model" => "gpt-realtime" }
      )
    end

    it "does not mutate the caller's request or response bodies" do
      request_body = { "api_key" => "sk-request-secret" }
      response_body = { "client_secret" => "cs-secret" }

      described_class.send_complete_request_log(**base_args, request_body: request_body, response_body: response_body)

      expect(request_body).to eq("api_key" => "sk-request-secret")
      expect(response_body).to eq("client_secret" => "cs-secret")
    end

    it "rescues an error from the API service, logs it, and does not raise" do
      allow(api_service).to receive(:send_llm_request_log).and_raise("network error")
      allow(Coolhand).to receive(:log)

      expect { described_class.send_complete_request_log(**base_args) }.not_to raise_error
      expect(Coolhand).to have_received(:log).with(/Error sending complete request log: network error/)
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

    it "returns an empty hash for nil" do
      expect(described_class.sanitize_headers(nil)).to eq({})
    end

    it "stringifies symbol keys and joins Array values on a plain Hash" do
      sanitized = described_class.sanitize_headers(
        Accept: %w[text/html application/json], "X-Api-Key": "k", "Content-Type" => "application/json"
      )

      expect(sanitized).to eq(
        "Accept" => "text/html, application/json",
        "X-Api-Key" => "[REDACTED]",
        "Content-Type" => "application/json"
      )
    end

    it "redacts a Net::HTTP request's Authorization header (the to_hash path real Net::HTTPHeader objects take)" do
      req = Net::HTTP::Get.new(URI("https://api.example.com/v1"))
      req["Authorization"] = "Bearer sk-live-secret"
      req["Accept"] = "application/json"

      sanitized = described_class.sanitize_headers(req)

      expect(sanitized["authorization"]).to eq("Bearer [REDACTED]")
      expect(sanitized["accept"]).to eq("application/json")
    end

    it "enumerates a header-like object that only responds to each_header, redacting sensitive values" do
      headers = Class.new do
        def each_header
          yield "Authorization", "Bearer sk-live-secret"
          yield "X-Api-Key", "k"
          yield :"Set-Cookie", "_session=abc"
          yield "Accept", %w[a b]
        end
      end.new

      expect(described_class.sanitize_headers(headers)).to eq(
        "Authorization" => "Bearer [REDACTED]",
        "X-Api-Key" => "[REDACTED]",
        "Set-Cookie" => "[REDACTED]",
        "Accept" => "a, b"
      )
    end

    it "enumerates a header-like object that only responds to each, redacting sensitive values" do
      headers = Class.new do
        def each
          yield :Authorization, "raw-token-without-bearer"
          yield "X-Goog-Api-Key", "k"
          yield "Content-Type", "application/json"
        end
      end.new

      expect(described_class.sanitize_headers(headers)).to eq(
        "Authorization" => "[REDACTED]",
        "X-Goog-Api-Key" => "[REDACTED]",
        "Content-Type" => "application/json"
      )
    end

    it "redacts an Array of header pairs (each branch)" do
      sanitized = described_class.sanitize_headers([["Cookie", "_session=abc"], ["Accept", "*/*"]])

      expect(sanitized).to eq("Cookie" => "[REDACTED]", "Accept" => "*/*")
    end

    it "fails closed for an object that supports no header enumeration, never logging its to_s" do
      headers = Object.new
      def headers.to_s
        "Authorization: Bearer sk-secret"
      end

      expect(described_class.sanitize_headers(headers)).to eq({})
    end
  end

  describe ".sensitive_header?" do
    it "keeps provider rate-limit telemetry headers that merely contain 'token'" do
      %w[x-ratelimit-limit-requests x-ratelimit-remaining-tokens x-ratelimit-reset-tokens
         anthropic-ratelimit-tokens-remaining anthropic-ratelimit-input-tokens-reset
         anthropic-ratelimit-output-tokens-limit X-RateLimit-Remaining-Tokens x-rate-limit-remaining].each do |name|
        expect(described_class.sensitive_header?(name)).to be(false), "expected #{name} to be kept"
      end
    end

    it "still redacts rate-limit lookalikes outside the closed vocabulary" do
      %w[x-ratelimit-api-key x-ratelimit-tokens-secret x-ratelimit-token ratelimit-auth
         x-auth-session-ratelimit-remaining x-ratelimit-remaining-tokens-key].each do |name|
        expect(described_class.sensitive_header?(name)).to be(true), "expected #{name} to be redacted"
      end
    end

    it "does not let a sensitive vendor prefix smuggle a header past redaction" do
      %w[api-key-ratelimit-reset secret-ratelimit-tokens auth-session-ratelimit-remaining
         x-token-ratelimit-limit].each do |name|
        expect(described_class.sensitive_header?(name)).to be(true), "expected #{name} to be redacted"
      end
    end

    it "redacts ordinary sensitive names and passes ordinary safe ones" do
      expect(described_class.sensitive_header?("x-api-key")).to be(true)
      expect(described_class.sensitive_header?("Set-Cookie")).to be(true)
      expect(described_class.sensitive_header?("content-type")).to be(false)
    end

    it "is applied by sanitize_headers" do
      sanitized = described_class.sanitize_headers(
        "x-ratelimit-remaining-tokens" => "1999", "anthropic-ratelimit-tokens-reset" => "2026-01-01T00:00:00Z",
        "x-api-key" => "sk-secret"
      )

      expect(sanitized).to eq(
        "x-ratelimit-remaining-tokens" => "1999", "anthropic-ratelimit-tokens-reset" => "2026-01-01T00:00:00Z",
        "x-api-key" => "[REDACTED]"
      )
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

    it "redacts the exact-name params code, sas, pwd and passwd, case-insensitively" do
      sanitized = described_class.sanitize_url("https://f.azurewebsites.net/api/x?code=FNKEY&SAS=s1&pwd=p1&passwd=p2&n=1")

      expect(sanitized).to eq(
        "https://f.azurewebsites.net/api/x?code=%5BREDACTED%5D&SAS=%5BREDACTED%5D&" \
        "pwd=%5BREDACTED%5D&passwd=%5BREDACTED%5D&n=1"
      )
    end

    it "sees through bracketed array-style names for the exact-name rule" do
      sanitized = described_class.sanitize_url("https://h.example/a?code[]=S1&a[sas]=S2&a[country_code]=US")

      expect(sanitized).to eq(
        "https://h.example/a?code[]=%5BREDACTED%5D&a[sas]=%5BREDACTED%5D&a[country_code]=US"
      )
    end

    it "does not treat names merely containing 'code' as sensitive" do
      url = "https://api.example.com/v1/x?encoding=utf-8&country_code=US&postcode=12345&codec=opus"

      expect(described_class.sanitize_url(url)).to eq(url)
    end

    it "leaves a URL with nothing to redact byte-for-byte unchanged" do
      url = "https://api.example.com/v1/models/gemini-1.5-pro:generateContent?alt=sse&a=b%20c&empty="

      expect(described_class.sanitize_url(url)).to eq(url)
    end

    it "redacts sensitive query params whatever the case of their names" do
      sanitized = described_class.sanitize_url("https://example.com/p?API_KEY=k1&Token=t1&page=2")

      expect(sanitized).not_to include("k1")
      expect(sanitized).not_to include("t1")
      expect(sanitized).to include("page=2")
    end

    it "returns a URL with no credentials unchanged" do
      url = "https://api.example.com/v1/chat?model=gpt-4&stream=true"

      expect(described_class.sanitize_url(url)).to eq(url)
    end

    it "redacts sensitive matrix params in the path" do
      sanitized = described_class.sanitize_url("https://api.example.com/v1;key=abc123/things;sig=xyz;ver=2/list")

      expect(sanitized).to eq(
        "https://api.example.com/v1;key=%5BREDACTED%5D/things;sig=%5BREDACTED%5D;ver=2/list"
      )
    end

    it "redacts a matrix param smuggled into a query value" do
      sanitized = described_class.sanitize_url("https://api.example.com/v1?a=1;key=SECRET&b=2")

      expect(sanitized).not_to include("SECRET")
      expect(sanitized).to eq("https://api.example.com/v1?a=1;key=%5BREDACTED%5D&b=2")
    end

    it "redacts the whole secret when a query matrix value contains '/'" do
      sanitized = described_class.sanitize_url("https://h.example/a?next=/a;key=SEC/ret/more&b=2")

      expect(sanitized).to eq("https://h.example/a?next=/a;key=%5BREDACTED%5D&b=2")
    end

    it "redacts exact-name matrix params that follow a non-sensitive name in a query segment" do
      %w[code sas pwd passwd].each do |name|
        sanitized = described_class.sanitize_url("https://h.example/a?x;#{name}=SECRET&y=1")

        expect(sanitized).to eq("https://h.example/a?x;#{name}=%5BREDACTED%5D&y=1")
      end
    end

    it "still redacts path matrix params when the URL is unparseable and falls back to fail-closed" do
      sanitized = described_class.sanitize_url("https://u:p@h.example/a;key=SECRET/{x}?code=S#f")

      expect(sanitized).to eq("https://REDACTED@h.example/a;key=%5BREDACTED%5D/{x}")
    end

    it "redacts percent-encoded sensitive param and matrix names" do
      sanitized = described_class.sanitize_url("https://h.example/a;%6Bey=S1?c%6Fde=S2")

      expect(sanitized).not_to include("S1")
      expect(sanitized).not_to include("S2")
    end

    it "does not raise on a percent-escaped invalid UTF-8 byte in a param or matrix name" do
      expect { described_class.sanitize_url("https://h.example/a;%FF=1?%FF=2&ok=3") }.not_to raise_error
      expect(described_class.sanitize_url("https://h.example/a?%FF=2&ok=3")).to eq("https://h.example/a?%FF=2&ok=3")
    end

    it "leaves relative URLs working" do
      expect(described_class.sanitize_url("/rel/path?code=S")).to eq("/rel/path?code=%5BREDACTED%5D")
    end

    describe "URL fragments" do
      it "drops the fragment along with redacting the query" do
        expect(described_class.sanitize_url("https://h.example/a?key=S#frag")).to eq(
          "https://h.example/a?key=%5BREDACTED%5D"
        )
      end

      it "drops a fragment that carries an OAuth implicit-flow token" do
        sanitized = described_class.sanitize_url("https://h.example/cb#access_token=SECRET&token_type=bearer")

        expect(sanitized).to eq("https://h.example/cb")
      end

      it "drops an empty fragment and a fragment on a relative URL" do
        expect(described_class.sanitize_url("https://h.example/a#")).to eq("https://h.example/a")
        expect(described_class.sanitize_url("/rel/path?code=S#access_token=SECRET")).to eq(
          "/rel/path?code=%5BREDACTED%5D"
        )
      end

      it "returns a URL without a fragment byte-for-byte" do
        url = "https://h.example/a?alt=sse&n=1"

        expect(described_class.sanitize_url(url)).to equal(url)
      end
    end

    it "fails closed on bare query segments that have no '='" do
      expect(described_class.sanitize_url("https://api.example.com/v1?sk-abc123")).to eq(
        "https://api.example.com/v1?%5BREDACTED%5D"
      )
      expect(described_class.sanitize_url("https://api.example.com/v1?alt=sse&sk-abc123&n=1")).to eq(
        "https://api.example.com/v1?alt=sse&%5BREDACTED%5D&n=1"
      )
    end

    it "does not alter a URL with an empty query" do
      expect(described_class.sanitize_url("https://api.example.com/v1?")).to eq("https://api.example.com/v1?")
    end

    it "fails closed on an unparseable URL with userinfo but no query or fragment" do
      sanitized = described_class.sanitize_url("https://user:pw@ho st/p")

      expect(sanitized).not_to include("user")
      expect(sanitized).not_to include("pw")
      expect(sanitized).to eq("https://REDACTED@ho st/p")
    end
  end

  describe "query-name and nesting-depth hardening" do
    it "redacts jwt, session, pass, sid and otp query params" do
      url = described_class.sanitize_url("https://h.example/a?jwt=J1&session=S1&pass=P1&sid=I1&otp=O1&page=2")

      expect(url).not_to match(/J1|S1|P1|I1|O1/)
      expect(url).to include("page=2")
    end

    it "does not log a body nested past the JSON depth limit as a raw string" do
      deep = "#{'[' * 101}{\"authorization\":\"Bearer sk-SECRET\"}#{']' * 101}"

      expect(described_class.parse_json(deep)).to eq("_coolhand_capture_skipped" => "nesting_too_deep")
    end
  end

  describe ".sanitize_body" do
    it "redacts credentials embedded in URL string values under data_sources" do
      body = {
        "data_sources" => [{
          "type" => "azure_search",
          "parameters" => {
            "endpoint" => "https://user:PASS@search.example.net/?sas=SASSECRET&api-version=1",
            "index_name" => "docs",
            "note" => "see https://example.com/?token=abc for details"
          }
        }]
      }

      params = described_class.sanitize_body(body)["data_sources"][0]["parameters"]

      expect(params["endpoint"]).to eq(
        "https://REDACTED@search.example.net/?sas=%5BREDACTED%5D&api-version=1"
      )
      expect(params["index_name"]).to eq("docs")
      # Prose containing a URL is not a bare URL value, so it is left alone.
      expect(params["note"]).to eq("see https://example.com/?token=abc for details")
    end

    it "drops a fragment from a URL value under data_sources" do
      body = { "data_sources" => [{ "parameters" => { "endpoint" => "https://search.example.net/#access_token=S" } }] }

      params = described_class.sanitize_body(body)["data_sources"][0]["parameters"]

      expect(params["endpoint"]).to eq("https://search.example.net/")
    end

    it "does not touch URL strings outside data_sources, such as prompt content" do
      body = { "messages" => [{ "role" => "user", "content" => "https://u:p@h.example/?token=abc" }] }

      expect(described_class.sanitize_body(body)).to eq(body)
    end

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

    it "redacts credential keys inside data_sources regardless of hyphen, space or case in the key name" do
      params = { "api-key" => "a", "Api Key" => "b", "CONNECTION-STRING" => "c", "Encoded-API-Key" => "d",
                 "index_name" => "docs" }

      sanitized = described_class.sanitize_body("data_sources" => [{ "parameters" => params }])

      expect(sanitized["data_sources"][0]["parameters"])
        .to eq("api-key" => "[REDACTED]", "Api Key" => "[REDACTED]", "CONNECTION-STRING" => "[REDACTED]",
          "Encoded-API-Key" => "[REDACTED]", "index_name" => "docs")
    end

    it "redacts credentials in arrays nested inside data_sources and leaves non-credential siblings alone" do
      body = {
        "data_sources" => [
          [{ "parameters" => { "key" => "deep-secret", "endpoint" => "https://search.example" } }],
          { "parameters" => { "fields" => [{ "token" => "t", "name" => "title" }] } }
        ]
      }

      sanitized = described_class.sanitize_body(body)

      expect(sanitized["data_sources"][0][0]["parameters"])
        .to eq("key" => "[REDACTED]", "endpoint" => "https://search.example")
      expect(sanitized["data_sources"][1]["parameters"]["fields"])
        .to eq([{ "token" => "[REDACTED]", "name" => "title" }])
    end

    it "passes scalar and nil data_sources values and entries through without raising" do
      expect(described_class.sanitize_body("data_sources" => nil)).to eq("data_sources" => nil)
      expect(described_class.sanitize_body("data_sources" => "none")).to eq("data_sources" => "none")
      expect(described_class.sanitize_body("data_sources" => [nil, "x", 3]))
        .to eq("data_sources" => [nil, "x", 3])
    end

    it "does not mutate the caller's body" do
      body = { "data_sources" => [{ "parameters" => { "key" => "top-secret" } }] }

      described_class.sanitize_body(body)

      expect(body["data_sources"][0]["parameters"]["key"]).to eq("top-secret")
    end
  end

  describe ".sanitize_body credential leaves" do
    def redact(body)
      described_class.sanitize_body(body)
    end

    it "redacts a top-level api_key" do
      expect(redact("api_key" => "sk-live", "model" => "gpt-4o")).to eq("api_key" => "[REDACTED]", "model" => "gpt-4o")
    end

    it "redacts every listed key name, matching case and separator style" do
      keys = %w[authorization authorization_token access_token refresh_token id_token api_key apikey client_secret
                private_key secret_key password]
      variants = keys + %w[Authorization authorizationToken accessToken refreshToken idToken apiKey API-KEY
                           clientSecret privateKey secretKey PASSWORD]
      body = variants.to_h { |k| [k, "s3cret"] }

      expect(redact(body).values.uniq).to eq(["[REDACTED]"])
    end

    it "handles symbol keys" do
      expect(redact(api_key: "sk-live", model: "m")).to eq(api_key: "[REDACTED]", model: "m")
    end

    it "redacts OpenAI Responses remote-MCP authorization and every headers value" do
      body = {
        "model" => "gpt-5",
        "tools" => [{
          "type" => "mcp", "server_label" => "stripe", "server_url" => "https://mcp.stripe.com",
          "authorization" => "oauth-access-token", "headers" => { "X-Api-Token" => "t0k", "X-Tenant" => "acme" },
          "require_approval" => "never"
        }]
      }

      tool = redact(body)["tools"][0]

      expect(tool).to eq(
        "type" => "mcp", "server_label" => "stripe", "server_url" => "https://mcp.stripe.com",
        "authorization" => "[REDACTED]", "headers" => { "X-Api-Token" => "[REDACTED]", "X-Tenant" => "[REDACTED]" },
        "require_approval" => "never"
      )
    end

    it "redacts headers on an entry that has server_url but no type, and on a symbol-keyed mcp tool" do
      expect(redact("server_url" => "https://m", "headers" => { "A" => "b" })["headers"]).to eq("A" => "[REDACTED]")
      expect(redact(type: "mcp", headers: { "A" => "b" })[:headers]).to eq("A" => "[REDACTED]")
    end

    it "leaves headers alone on objects that are not MCP tools" do
      body = { "type" => "http_echo", "headers" => { "Host" => "example.com" } }

      expect(redact(body)).to eq(body)
    end

    it "redacts Anthropic mcp_servers authorization_token and keeps the rest" do
      body = { "mcp_servers" => [{ "type" => "url", "url" => "https://m.example/sse", "name" => "m",
                                   "authorization_token" => "tok" }] }

      expect(redact(body)["mcp_servers"][0]).to eq(
        "type" => "url", "url" => "https://m.example/sse", "name" => "m", "authorization_token" => "[REDACTED]"
      )
    end

    it "redacts the legacy Realtime client_secret object's value but keeps expires_at" do
      body = { "id" => "sess_1", "client_secret" => { "value" => "ek_abc", "expires_at" => 1_900_000_000 } }

      expect(redact(body)).to eq(
        "id" => "sess_1", "client_secret" => { "value" => "[REDACTED]", "expires_at" => 1_900_000_000 }
      )
    end

    it "redacts a client_secret given as a plain string" do
      expect(redact("client_secret" => "cs-secret")).to eq("client_secret" => "[REDACTED]")
    end

    it "redacts the GA Realtime client-secret value and the credentials echoed in its session" do
      body = {
        "value" => "ek_abc", "expires_at" => 1_900_000_000,
        "session" => { "type" => "realtime",
                       "tools" => [{ "type" => "mcp", "authorization" => "a", "headers" => { "h" => "v" } }] }
      }

      sanitized = redact(body)

      expect(sanitized["value"]).to eq("[REDACTED]")
      expect(sanitized["expires_at"]).to eq(1_900_000_000)
      expect(sanitized["session"]["tools"][0]).to eq(
        "type" => "mcp", "authorization" => "[REDACTED]", "headers" => { "h" => "[REDACTED]" }
      )
    end

    it "leaves a bare value alone when there is no numeric expires_at beside it" do
      expect(redact("value" => "42 apples")).to eq("value" => "42 apples")
      expect(redact("value" => "x", "expires_at" => "tomorrow")).to eq("value" => "x", "expires_at" => "tomorrow")
      expect(redact("expires_at" => 1)).to eq("expires_at" => 1)
    end

    it "does not mangle tool JSON schemas that have properties named like credentials" do
      schema = {
        "tools" => [{
          "type" => "function",
          "function" => {
            "name" => "login",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "key" => { "type" => "string" }, "token" => { "type" => "string" },
                "api_key" => { "type" => "string", "description" => "the key" },
                "authorization" => { "type" => "object", "properties" => { "scheme" => { "type" => "string" } } },
                "password" => { "type" => "string" }
              },
              "required" => %w[api_key password]
            }
          }
        }]
      }

      expect(redact(schema)).to eq(schema)
    end

    it "leaves usage counts, model output text and non-string values alone" do
      body = {
        "usage" => { "total_tokens" => 120, "input_tokens" => 100, "output_tokens" => 20 },
        "max_tokens" => 256,
        "choices" => [{ "message" => { "role" => "assistant",
                                       "content" => "Set the authorization header and your api_key, token: abc" } }],
        "api_key" => nil,
        "password" => 12_345,
        "authorization" => { "scheme" => "bearer" }
      }

      expect(redact(body)).to eq(body)
    end

    it "walks arrays at the root and nested arrays of arrays" do
      expect(redact([{ "api_key" => "a" }, [{ "authorization" => "b" }]]))
        .to eq([{ "api_key" => "[REDACTED]" }, [{ "authorization" => "[REDACTED]" }]])
    end

    it "does not mutate its input" do
      body = { "tools" => [{ "type" => "mcp", "authorization" => "a", "headers" => { "h" => "v" } }] }
      snapshot = Marshal.load(Marshal.dump(body))

      redact(body)

      expect(body).to eq(snapshot)
    end

    it "passes nil, strings (including streamed SSE) and other non-JSON bodies through unchanged" do
      sse = "data: {\"api_key\":\"sk-live\"}\n\n"

      expect(redact(nil)).to be_nil
      expect(redact(sse)).to eq(sse)
      expect(redact(42)).to eq(42)
    end

    it "keeps redacting data_sources credentials when they are nested under other keys" do
      body = { "request" => { "data_sources" => [{ "parameters" => { "key" => "k" } }] } }

      expect(redact(body)["request"]["data_sources"][0]["parameters"]["key"]).to eq("[REDACTED]")
    end

    describe "data_sources at any depth" do
      let(:source) do
        { "type" => "azure_search",
          "parameters" => { "authentication" => { "type" => "api_key", "key" => "sk-search" },
                            "endpoint" => "https://u:P@h.example/?sas=S", "index_name" => "docs" } }
      end

      it "redacts credentials and URL leaves in a data_sources key nested several levels deep" do
        sanitized = redact("input" => { "request" => { "data_sources" => [source] } })

        params = sanitized["input"]["request"]["data_sources"][0]["parameters"]
        expect(params["authentication"]).to eq("type" => "api_key", "key" => "[REDACTED]")
        expect(params["endpoint"]).to eq("https://REDACTED@h.example/?sas=%5BREDACTED%5D")
        expect(params["index_name"]).to eq("docs")
      end

      it "redacts a dataSources key inside each object of an array, such as batch items" do
        item = { "body" => { "dataSources" => [source] } }
        body = { "requests" => [item, item] }

        sanitized = redact(body)

        sanitized["requests"].each do |entry|
          params = entry["body"]["dataSources"][0]["parameters"]
          expect(params["authentication"]["key"]).to eq("[REDACTED]")
          expect(params["endpoint"]).to eq("https://REDACTED@h.example/?sas=%5BREDACTED%5D")
        end
      end

      it "treats a top-level data_sources key exactly as before" do
        sanitized = redact("data_sources" => [source])

        expect(sanitized["data_sources"][0]["parameters"]["authentication"]["key"]).to eq("[REDACTED]")
      end

      it "does not raise when a nested data_sources value is not an Array" do
        items = [{ "data_sources" => nil }, { "data_sources" => 3 }]
        body = { "input" => { "data_sources" => "none", "items" => items } }
        snapshot = Marshal.load(Marshal.dump(body))

        expect(redact(body)).to eq(snapshot)
        expect(body).to eq(snapshot)
      end

      it "scrubs a URL string given directly as a nested data_sources value" do
        sanitized = redact("input" => { "data_sources" => "https://u:P@h.example/?sas=S" })

        expect(sanitized["input"]["data_sources"]).to eq("https://REDACTED@h.example/?sas=%5BREDACTED%5D")
      end

      it "handles symbol keys and arrays nested inside arrays" do
        symbol_source = { parameters: { authentication: { key: "sk-search" }, index_name: "docs" } }

        sanitized = redact(input: [[{ dataSources: [symbol_source] }]])

        expect(sanitized[:input][0][0][:dataSources][0][:parameters])
          .to eq(authentication: { key: "[REDACTED]" }, index_name: "docs")
      end

      it "leaves URL strings and key-like names outside data_sources untouched at the same depth" do
        body = { "input" => { "note" => "https://u:P@h.example/?sas=S", "metadata" => { "key" => "visible" },
                              "data_sources" => [source] } }

        sanitized = redact(body)

        expect(sanitized["input"]["note"]).to eq("https://u:P@h.example/?sas=S")
        expect(sanitized["input"]["metadata"]).to eq("key" => "visible")
      end

      it "does not mutate the input when data_sources is nested" do
        body = { "input" => [{ "data_sources" => [source] }] }
        snapshot = Marshal.load(Marshal.dump(body))

        redact(body)

        expect(body).to eq(snapshot)
      end

      it "applies the depth guard to a nested data_sources subtree" do
        deep = { "leaf" => "visible" }
        500.times { deep = { "n" => deep } }

        sanitized = nil
        expect { sanitized = redact("input" => { "data_sources" => deep }) }.not_to raise_error
        expect(sanitized.to_s).not_to include("visible")
      end
    end

    it "replaces subtrees nested deeper than 100 levels instead of recursing without bound" do
      deep = { "api_key" => "x", "secret_holder" => "y" }
      1000.times { deep = { "n" => deep } }

      sanitized = nil
      expect { sanitized = redact(deep) }.not_to raise_error
      expect(sanitized.to_s).not_to include("secret_holder")
      expect(sanitized.to_s).to include("[REDACTED]")
    end

    it "still scrubs URL credentials inside data_sources when reached through the shared walk, and only there" do
      body = { "data_sources" => [{ "parameters" => { "endpoint" => "https://u:P@h.example/?sas=S" } }],
               "note" => "https://u:P@h.example/?sas=S" }

      sanitized = redact(body)

      expect(sanitized["data_sources"][0]["parameters"]["endpoint"]).to eq("https://REDACTED@h.example/?sas=%5BREDACTED%5D")
      expect(sanitized["note"]).to eq("https://u:P@h.example/?sas=S")
    end

    it "applies the depth guard inside data_sources too" do
      deep = { "leaf" => "visible" }
      500.times { deep = { "n" => deep } }

      sanitized = nil
      expect { sanitized = redact("data_sources" => deep) }.not_to raise_error
      expect(sanitized.to_s).not_to include("visible")
    end

    it "accepts frozen input and non-String or nil keys without raising" do
      body = { "api_key" => "s", nil => 1, 7 => { "authorization" => "a" }, :sym => "ok" }.freeze

      expect(redact(body)).to eq("api_key" => "[REDACTED]", nil => 1, 7 => { "authorization" => "[REDACTED]" },
        sym: "ok")
    end

    it "applies the depth guard along a chain of nested client_secret objects" do
      deep = { "value" => "ek_leaf" }
      5000.times { deep = { "client_secret" => deep } }

      sanitized = nil
      expect { sanitized = redact(deep) }.not_to raise_error
      expect(sanitized.to_s).not_to include("ek_leaf")
    end

    it "still walks MCP headers that are not a flat map of strings" do
      tool = { "type" => "mcp", "headers" => [{ "Authorization" => "x" }] }
      nested = { "type" => "mcp", "headers" => { "X" => { "Authorization" => "y" }, "Retries" => 3 } }

      expect(redact(tool)["headers"]).to eq([{ "Authorization" => "[REDACTED]" }])
      expect(redact(nested)["headers"]).to eq("X" => { "Authorization" => "[REDACTED]" }, "Retries" => 3)
    end

    it "redacts deeply nested but in-range credentials" do
      body = { "a" => { "b" => [{ "c" => { "api_key" => "s" } }] } }

      expect(redact(body)["a"]["b"][0]["c"]["api_key"]).to eq("[REDACTED]")
    end
  end

  describe "red-team hardening" do
    it "redacts auth-style header names the old pattern missed" do
      headers = { "X-Auth" => "s1", "X-Authentication" => "s2", "Password" => "s3", "X-Credential" => "s4",
                  "X-Session-Id" => "s5", "X-Bearer" => "s6", "X-Jwt" => "s7", "Content-Type" => "application/json" }

      sanitized = described_class.sanitize_headers(headers)

      expect(sanitized.values_at("X-Auth", "X-Authentication", "Password", "X-Credential", "X-Session-Id",
        "X-Bearer", "X-Jwt")).to all(eq("[REDACTED]"))
      expect(sanitized["Content-Type"]).to eq("application/json")
    end

    it "fails closed on an unparseable URL by dropping userinfo, query and fragment" do
      sanitized = described_class.sanitize_url("https://user:pw@host.example.com/p?a=%zz&key=SECRET#frag")

      expect(sanitized).to eq("https://REDACTED@host.example.com/p")
    end

    it "redacts data_sources regardless of the key's case or separator style" do
      %w[Data_Sources dataSources DATA-SOURCES].each do |outer|
        sanitized = described_class.sanitize_body(outer => [{ "parameters" => { "key" => "secret" } }])

        expect(sanitized[outer][0]["parameters"]["key"]).to eq("[REDACTED]")
      end
    end

    it "redacts pwd/passwd/bearer/jwt credential keys inside data_sources" do
      params = { "pwd" => "a", "passwd" => "b", "bearer_value" => "c", "jwt" => "d", "index_name" => "docs" }

      sanitized = described_class.sanitize_body("data_sources" => [{ "parameters" => params }])

      expect(sanitized["data_sources"][0]["parameters"])
        .to eq("pwd" => "[REDACTED]", "passwd" => "[REDACTED]", "bearer_value" => "[REDACTED]",
          "jwt" => "[REDACTED]", "index_name" => "docs")
    end
  end
end
