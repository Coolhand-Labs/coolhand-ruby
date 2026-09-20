# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::NetHttpInterceptor do
  let(:interceptor) { Class.new { include Coolhand::NetHttpInterceptor }.new }

  before do
    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES.dup
    end
  end

  def intercepted?(url)
    interceptor.send(:intercept?, url)
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

    it "can be extended for a non-default host with a user entry" do
      Coolhand.configuration.intercept_addresses += ["192.168.1.5:11434/api/chat"]
      expect(intercepted?("http://192.168.1.5:11434/api/chat")).to be true
      expect(intercepted?("http://192.168.1.6:11434/api/chat")).to be false
    end
  end

  it "keeps the existing defaults intercepted" do
    expect(intercepted?("https://api.openai.com/v1/chat/completions")).to be true
    expect(intercepted?("https://bedrock-runtime.us-east-1.amazonaws.com/model/x/converse")).to be true
  end
end
