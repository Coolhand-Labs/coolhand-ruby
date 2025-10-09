# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe Coolhand::Interceptor do
  let(:logger) { class_double(Coolhand::Logger) }
  let(:conn) do
    Faraday.new do |builder|
      builder.use described_class
      builder.adapter :test do |stub|
        stub.get("/hello") { [200, { "Content-Type" => "application/json" }, '{"msg":"hi"}'] }
      end
    end
  end

  before do
    stub_const("Coolhand::Logger", logger)
    allow(logger).to receive(:log_to_api)
    allow(Coolhand).to receive(:log)

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.api_endpoint = "http://localhost:3000/test"
      c.intercept_address = ["hello"]
    end
  end

  it "intercepts a Faraday request and logs the response body" do
    conn.get("/hello")

    # Give thread a chance to run
    sleep 0.1

    expect(logger).to have_received(:log_to_api).with(
      a_hash_including(
        url: "http:/hello",
        method: :get,
        response_body: { "msg" => "hi" },
        status_code: 200
      )
    )
  end

  describe ".patch! and .unpatch!" do
    let(:original_method) { Faraday::Connection.instance_method(:initialize) }

    after do
      # Ensure we leave Faraday in original state after tests
      described_class.unpatch!
    end

    it "patches Faraday::Connection to use the Interceptor" do
      described_class.unpatch!

      expect(Faraday::Connection.private_method_defined?(described_class::ORIGINAL_METHOD_ALIAS)).to be false

      described_class.patch!

      expect(Faraday::Connection.private_method_defined?(described_class::ORIGINAL_METHOD_ALIAS)).to be true

      # Check that new initialize actually uses Interceptor
      conn = Faraday.new do |builder|
        builder.adapter :test, Faraday::Adapter::Test::Stubs.new
      end

      # Check that the middleware stack includes Interceptor
      stack_classes = conn.builder.handlers.map(&:klass)
      expect(stack_classes).to include(described_class)
    end

    it "unpatches Faraday::Connection correctly" do
      described_class.patch!
      expect(Faraday::Connection.private_method_defined?(described_class::ORIGINAL_METHOD_ALIAS)).to be true

      described_class.unpatch!
      expect(Faraday::Connection.private_method_defined?(described_class::ORIGINAL_METHOD_ALIAS)).to be false

      # Ensure initialize is back to original
      expect(Faraday::Connection.instance_method(:initialize)).to eq(original_method)
    end
  end
end
