# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::NetHttpInterceptor do
  let(:interceptor) { Coolhand::NetHttpInterceptor::Helpers }

  before do
    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES.dup
    end
  end

  def intercepted?(url)
    interceptor.intercept?(url)
  end

  describe "host-wide providers" do
    %w[api.deepseek.com api.mistral.ai api.perplexity.ai api.x.ai].each do |host|
      it "intercepts #{host}" do
        expect(intercepted?("https://#{host}/v1/chat/completions")).to be true
      end
    end

    it "does not intercept a look-alike host" do
      expect(intercepted?("https://api.deepseek.com.evil.net/v1/chat/completions")).to be false
      expect(intercepted?("https://evil.net/?to=api.x.ai")).to be false
    end
  end

  describe "Cohere (path-scoped)" do
    supported_paths = %w[/v2/chat /v1/embed /v2/embed]
    unsupported_paths = %w[/v1/chat /v1/rerank /v2/rerank /v1/tokenize /v1/classify /v1/embed-jobs /v1/models]

    %w[api.cohere.com api.cohere.ai].each do |host|
      supported_paths.each do |path|
        it "intercepts https://#{host}#{path}" do
          expect(intercepted?("https://#{host}#{path}")).to be true
        end
      end

      unsupported_paths.each do |path|
        it "does not intercept https://#{host}#{path}" do
          expect(intercepted?("https://#{host}#{path}")).to be false
        end
      end
    end
  end

  describe "TypeSafe Jev / System One" do
    it "intercepts /v1/systemone" do
      expect(intercepted?("https://api.typesafe.ai/v1/systemone")).to be true
    end

    it "does not intercept other paths on the host" do
      expect(intercepted?("https://api.typesafe.ai/v1/models")).to be false
      expect(intercepted?("https://api.typesafe.ai/v1/systemones")).to be false
    end
  end

  describe "Ollama (port- and path-scoped)" do
    %w[/api/chat /api/generate /api/embed /api/embeddings].each do |path|
      it "intercepts localhost:11434#{path}" do
        expect(intercepted?("http://localhost:11434#{path}")).to be true
      end

      it "intercepts 127.0.0.1:11434#{path}" do
        expect(intercepted?("http://127.0.0.1:11434#{path}")).to be true
      end

      it "intercepts a bare compose-service host on 11434#{path}" do
        expect(intercepted?("http://ollama:11434#{path}")).to be true
      end
    end

    it "does not intercept an unrelated host's own /api/chat" do
      expect(intercepted?("https://myapp.example.com/api/chat")).to be false
      expect(intercepted?("https://myapp.example.com:11434/api/chat")).to be false
      expect(intercepted?("http://localhost:3000/api/chat")).to be false
    end

    it "does not intercept other Ollama endpoints on the default port" do
      expect(intercepted?("http://localhost:11434/api/tags")).to be false
      expect(intercepted?("http://localhost:11434/api/pull")).to be false
    end

    it "intercepts the IPv6 loopback on 11434 by default" do
      expect(intercepted?("http://[::1]:11434/api/chat")).to be true
      expect(intercepted?("http://[::1]:11434/api/tags")).to be false
    end

    it "does not match a LAN IP until a user entry is added" do
      expect(intercepted?("http://192.168.1.5:11434/api/chat")).to be false
    end

    it "can be extended for a non-default host with a user entry" do
      Coolhand.configuration.intercept_addresses += ["192.168.1.5:11434/api/chat"]
      expect(intercepted?("http://192.168.1.5:11434/api/chat")).to be true
      expect(intercepted?("http://192.168.1.6:11434/api/chat")).to be false
    end
  end

  describe "Bedrock endpoint variants" do
    intercepted_hosts = %w[
      bedrock-runtime.us-east-1.amazonaws.com
      bedrock-runtime.cn-north-1.amazonaws.com.cn
      bedrock-runtime-fips.us-gov-west-1.amazonaws.com
      bedrock-runtime.us-east-1.api.aws
      bedrock-runtime-fips.us-gov-west-1.api.aws
    ]

    intercepted_hosts.each do |host|
      it "intercepts #{host}" do
        expect(intercepted?("https://#{host}/model/anthropic.claude-3/invoke")).to be true
      end
    end

    it "does not intercept the control-plane host or a region-less host" do
      expect(intercepted?("https://bedrock.us-east-1.amazonaws.com/model/x/invoke")).to be false
      expect(intercepted?("https://bedrock-runtime.amazonaws.com/model/x/invoke")).to be false
    end

    it "does not intercept a look-alike host" do
      expect(intercepted?("https://bedrock-runtime.us-east-1.amazonaws.com.evil.net/model/x/invoke")).to be false
      expect(intercepted?("https://notbedrock-runtime.us-east-1.amazonaws.com/model/x/invoke")).to be false
    end

    it "does not intercept a multi-label region, since \"*\" is one label" do
      expect(intercepted?("https://bedrock-runtime.evil.s3.amazonaws.com/model/x/invoke")).to be false
    end
  end

  describe "user-supplied address entries" do
    def with_addresses(*addresses)
      Coolhand.configuration.intercept_addresses = addresses
    end

    it "tolerates a trailing slash on a path-scoped entry" do
      with_addresses("host.example.com/openai/")
      expect(intercepted?("https://host.example.com/openai")).to be true
      expect(intercepted?("https://host.example.com/openai/v1/chat")).to be true
      expect(intercepted?("https://host.example.com/openaiz")).to be false
    end

    it "matches a bare host:port entry regardless of path" do
      with_addresses("localhost:8080")
      expect(intercepted?("http://localhost:8080/anything")).to be true
      expect(intercepted?("http://localhost:9090/anything")).to be false
    end

    it "matches hosts case-insensitively" do
      with_addresses("Host.Example.com/openai")
      expect(intercepted?("https://HOST.example.com/openai/x")).to be true
    end

    it "still lets exclude_api_patterns veto a path-scoped hit" do
      with_addresses("host.example.com/openai")
      Coolhand.configuration.exclude_api_patterns = ["/openai/batches"]
      expect(intercepted?("https://host.example.com/openai/chat")).to be true
      expect(intercepted?("https://host.example.com/openai/batches")).to be false
    end
  end

  it "still matches a bare-host default on a non-default port" do
    expect(intercepted?("https://api.openai.com:8443/v1/chat/completions")).to be true
  end

  it "keeps the existing defaults intercepted" do
    expect(intercepted?("https://api.openai.com/v1/chat/completions")).to be true
    expect(intercepted?("https://bedrock-runtime.us-east-1.amazonaws.com/model/x/converse")).to be true
  end

  it "matches a fully-qualified trailing-dot host" do
    expect(intercepted?("https://api.openai.com./v1/chat/completions")).to be true
    expect(intercepted?("https://api.openai.com.evil.net./v1/chat/completions")).to be false
  end

  describe "path normalization before exclude and anchor matching" do
    azure = "https://my.openai.azure.com"
    cohere = "https://api.cohere.com"

    it "still excludes the plain Azure control-plane path" do
      expect(intercepted?("#{azure}/openai/files")).to be false
    end

    {
      "repeated slashes" => "/openai//files",
      "a dot segment" => "/openai/./files",
      "an unreserved percent-escape" => "/openai/%66iles",
      "an escaped leading segment" => "/%6fpenai/files",
      "an encoded dot segment" => "/openai/%2e/files",
      "a parent segment" => "/openai/chat/../files",
      "a parent segment past the root" => "/../../openai/files",
      "a trailing dot segment" => "/openai/files/."
    }.each do |label, path|
      it "excludes #{path} (#{label})" do
        expect(intercepted?("#{azure}#{path}")).to be false
      end
    end

    it "does not let ../ climb out of the excluded prefix into inference paths" do
      expect(intercepted?("#{azure}/openai/files/../deployments/gpt/chat/completions")).to be true
    end

    it "does not match a Cohere anchor through a parent-segment walk to another endpoint" do
      expect(intercepted?("#{cohere}/v2/chat/../../v1/rerank")).to be false
      expect(intercepted?("#{cohere}/v2/chat/../rerank")).to be false
    end

    it "matches a Cohere anchor reached through sloppy but equivalent paths" do
      expect(intercepted?("#{cohere}//v2/chat")).to be true
      expect(intercepted?("#{cohere}/%76%32/chat")).to be true
      expect(intercepted?("#{cohere}/v1/../v2/chat")).to be true
      expect(intercepted?("#{cohere}/v2/./chat")).to be true
    end

    it "leaves reserved escapes encoded so %2F cannot forge a segment boundary" do
      expect(intercepted?("#{azure}/openai%2Ffiles")).to be true
      expect(intercepted?("#{cohere}/v2%2Fchat")).to be false
    end

    it "decodes only one level, so a double-encoded dot stays literal" do
      expect(intercepted?("#{azure}/openai/%252e/files")).to be true
    end

    it "keeps normal paths unchanged" do
      expect(intercepted?("#{azure}/openai/deployments/gpt/chat/completions")).to be true
      expect(intercepted?("#{cohere}/v2/chat")).to be true
      expect(intercepted?("#{cohere}/v2/chat/")).to be true
      expect(intercepted?("#{cohere}/v1/rerank")).to be false
    end

    it "does not treat the query string as part of the path" do
      expect(intercepted?("#{azure}/openai/deployments/x?next=/openai//files")).to be true
      expect(intercepted?("#{cohere}/v1/rerank?x=/v2/chat")).to be false
      expect(intercepted?("#{cohere}/v2/chat?x=../../v1/rerank")).to be true
    end

    it "does not create false exclusions from near-miss paths" do
      expect(intercepted?("#{azure}/openai/deployments/files-and-more/chat")).to be true
      expect(intercepted?("#{azure}/openai/%66ile/chat")).to be true
    end

    it "keeps path matching case-sensitive" do
      expect(intercepted?("#{azure}/OpenAI/files")).to be true
      expect(intercepted?("#{cohere}/V2/chat")).to be false
    end

    describe "Helpers.normalize_path" do
      it "normalizes without touching the trailing slash" do
        expect(interceptor.normalize_path("/a//b/./c/../d/")).to eq("/a/b/d/")
        expect(interceptor.normalize_path("/a/b/..")).to eq("/a/")
        expect(interceptor.normalize_path("/")).to eq("/")
        expect(interceptor.normalize_path("/..")).to eq("/")
      end

      it "decodes unreserved escapes in any hex case and leaves other escapes alone" do
        expect(interceptor.normalize_path("/%41%7e%5f%2D%2e/%2f%3a%20")).to eq("/A~_-./%2f%3a%20")
      end

      it "leaves malformed escapes as they are instead of raising" do
        expect(interceptor.normalize_path("/a/%zz/%4/%")).to eq("/a/%zz/%4/%")
      end

      it "falls back to the raw path if normalization fails" do
        bad = Object.new.tap { |o| o.define_singleton_method(:gsub) { |*| raise ArgumentError, "boom" } }
        expect(interceptor.normalize_path(bad)).to equal(bad)
      end
    end
  end

  describe "misconfigured rules never break the host request" do
    let(:http) { Net::HTTP.new("api.openai.com", 443).tap { |h| h.use_ssl = true } }

    before do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(status: 200, body: "{}")
    end

    it "still performs the real request when exclude_api_patterns is not an array" do
      Coolhand.configuration.exclude_api_patterns = "/foo"

      response = http.post("/v1/chat/completions", "{}", "Content-Type" => "application/json")

      expect(response.code).to eq("200")
    end

    it "still performs the real request when exclude_api_patterns holds a non-string" do
      Coolhand.configuration.exclude_api_patterns = [:sym]

      response = http.post("/v1/chat/completions", "{}", "Content-Type" => "application/json")

      expect(response.code).to eq("200")
    end
  end
end
