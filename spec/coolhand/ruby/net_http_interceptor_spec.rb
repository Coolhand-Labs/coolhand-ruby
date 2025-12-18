# frozen_string_literal: true

require "spec_helper"
require "net/http"
require_relative "../../../lib/coolhand/ruby/net_http_interceptor"

RSpec.describe Coolhand::Ruby::NetHttpInterceptor do
  let(:api_service_instance) { instance_double(Coolhand::Ruby::ApiService) }
  let(:api_service_class) { class_double(Coolhand::Ruby::ApiService).as_stubbed_const }

  before do
    allow(api_service_class).to receive(:new).and_return(api_service_instance)
    allow(api_service_instance).to receive(:send_llm_request_log)
    allow(Coolhand).to receive(:log)

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["api.openai.com"]
    end
  end

  describe ".patch! and .unpatch!" do
    after do
      described_class.unpatch!
    end

    it "marks patched and unpatched correctly" do
      described_class.unpatch!
      expect(described_class.patched?).to be false

      described_class.patch!
      expect(described_class.patched?).to be true

      described_class.unpatch!
      expect(described_class.patched?).to be false

      expect { described_class.patch! }.not_to raise_error
      expect(described_class.patched?).to be true
    end
  end

  describe "helper methods" do
    let(:http_obj) { Net::HTTP.new("api.openai.com", 443).tap { |h| h.use_ssl = true } }
    let(:req) { Net::HTTP::Post.new("/v1/chat/completions") }

    it "builds a full url and call data correctly" do
      interceptor = described_class.new

      url = interceptor.build_url_for_request(http_obj, req)
      expect(url).to include("https://api.openai.com")
      expect(url).to include("/v1/chat/completions")

      call_data = interceptor.build_call_data_for_request(http_obj, req, '{"a":1}', url)
      expect(call_data[:url]).to eq(url)
      expect(call_data[:request_body]).to eq({})
      expect(call_data[:method]).to eq("post")
      expect(call_data[:request_headers]).to be_a(Hash)
    end
  end
end

