# frozen_string_literal: true

require "spec_helper"
require "faraday"

# rubocop:disable RSpec/VerifiedDoubles

RSpec.describe Coolhand::Ruby::FaradayInterceptor do
  let(:api_service_instance) { instance_double(Coolhand::Ruby::ApiService) }
  let(:api_service_class) { class_double(Coolhand::Ruby::ApiService).as_stubbed_const }
  let(:conn) do
    Faraday.new do |builder|
      builder.adapter :test do |stub|
        stub.get("/hello") { [200, { "Content-Type" => "application/json" }, '{"msg":"hi"}'] }
      end
    end
  end

  before do
    allow(api_service_class).to receive(:new).and_return(api_service_instance)
    allow(api_service_instance).to receive(:send_llm_request_log)
    allow(Coolhand).to receive(:log)

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["hello"]
    end
  end

  it "intercepts a Faraday request and logs the response body" do
    conn.get("/hello")

    # Give thread a chance to run
    sleep 0.1

    expect(api_service_instance).to have_received(:send_llm_request_log).with(
      a_hash_including(
        raw_request: a_hash_including(
          url: "http:/hello",
          method: "get",
          response_body: { "msg" => "hi" },
          status_code: 200
        )
      )
    )
  end

  describe ".patch! and .unpatch!" do
    after do
      # Ensure we clean up the patched state after tests
      described_class.unpatch!
    end

    it "patches Faraday::Connection to use the Interceptor with prepend" do
      described_class.unpatch!
      expect(described_class.patched?).to be false

      described_class.patch!
      expect(described_class.patched?).to be true

      # Check that new connections automatically include Interceptor
      conn = Faraday.new do |builder|
        builder.adapter :test, Faraday::Adapter::Test::Stubs.new
      end

      # Check that the middleware stack includes Interceptor
      stack_classes = conn.builder.handlers.map(&:klass)
      expect(stack_classes).to include(described_class)
    end

    it "prevents duplicate interceptors when already patched" do
      described_class.patch!

      # Create multiple connections - should only have one interceptor each
      conn1 = Faraday.new("https://api.example.com")
      conn2 = Faraday.new("https://api.example.com")

      interceptor_count1 = conn1.builder.handlers.count { |h| h.klass == described_class }
      interceptor_count2 = conn2.builder.handlers.count { |h| h.klass == described_class }

      expect(interceptor_count1).to eq(1)
      expect(interceptor_count2).to eq(1)
    end

    it "marks as unpatched when unpatch! is called" do
      described_class.patch!
      expect(described_class.patched?).to be true

      described_class.unpatch!
      expect(described_class.patched?).to be false

      # NOTE: With prepend, the module remains in the ancestor chain
      # but the patched? flag prevents re-patching
    end

    it "allows re-patching after unpatch!" do
      described_class.patch!
      described_class.unpatch!

      expect(described_class.patched?).to be false

      # Should be able to patch again
      expect { described_class.patch! }.not_to raise_error
      expect(described_class.patched?).to be true
    end
  end

  describe "#call" do
    let(:interceptor) { described_class.new }
    let(:app) { double("app") }
    let(:request_double) { double("request", on_data: nil).tap { |d| allow(d).to receive(:on_data=) } }
    let(:env) do
      double("env",
        url: double(to_s: "https://api.openai.com/v1/chat/completions"),
        method: :post,
        request_headers: { "Authorization" => "Bearer test" },
        request_body: '{"model":"gpt-4","messages":[]}',
        request: request_double)
    end

    # Mock Faraday response object that supports on_complete
    let(:faraday_response) do
      double("faraday_response").tap do |response|
        allow(response).to receive(:on_complete).and_yield(response_env)
      end
    end

    let(:response_env) do
      double("response_env",
        body: '{"choices":[{"message":{"content":"Hello"}}]}',
        response_headers: { "content-type" => "application/json" },
        status: 200)
    end

    before do
      interceptor.instance_variable_set(:@app, app)
      allow(Coolhand.configuration).to receive(:intercept_addresses).and_return(["api.openai.com"])
    end

    context "when thread-local Faraday suppression is enabled" do
      before do
        Thread.current[:coolhand_disable_faraday] = true
        # When suppressed, app.call should return a proper Faraday response
        allow(app).to receive(:call).with(env).and_return(faraday_response)
      end

      after do
        Thread.current[:coolhand_disable_faraday] = false
      end

      it "skips interception and calls super directly" do
        expect(app).to receive(:call).with(env).and_return(faraday_response)
        expect(interceptor).not_to receive(:build_call_data)

        # The key behavior is that it calls super without doing any interception
        interceptor.call(env)
      end

      it "does not log the request" do
        expect(Coolhand).not_to receive(:log).with(/INTERCEPTING/)

        interceptor.call(env)
      end
    end

    context "when thread-local Faraday suppression is disabled" do
      before do
        Thread.current[:coolhand_disable_faraday] = false
        allow(app).to receive(:call).with(env).and_return(faraday_response)

        # Mock interceptor methods
        allow(interceptor).to receive_messages(parse_json: {}, sanitize_headers: {})
        allow(interceptor).to receive(:send_complete_request_log)
      end

      it "proceeds with normal interception" do
        expect(Coolhand).to receive(:log).with(/INTERCEPTING/)

        interceptor.call(env)
      end

      it "processes the request normally" do
        expect(interceptor).to receive(:build_call_data).with(env).and_call_original

        interceptor.call(env)
      end
    end

    context "when request is not for an LLM API" do
      let(:non_llm_env) do
        double("env",
          url: double(to_s: "https://example.com/api"),
          method: :get)
      end

      it "skips interception regardless of thread-local flag state" do
        Thread.current[:coolhand_disable_faraday] = false

        expect(app).to receive(:call).with(non_llm_env).and_return(faraday_response)
        expect(interceptor).not_to receive(:build_call_data)

        # The key behavior is that it skips interception for non-LLM requests
        interceptor.call(non_llm_env)
      end
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
