# frozen_string_literal: true

require "spec_helper"
require "faraday"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Duplicate Request Prevention" do
  let(:api_service_instance) { instance_double(Coolhand::ApiService) }
  let(:api_service_class) { class_double(Coolhand::ApiService).as_stubbed_const }

  before do
    allow(api_service_class).to receive(:new).and_return(api_service_instance)
    allow(api_service_instance).to receive(:send_llm_request_log)
    allow(Coolhand).to receive(:log)

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["api.anthropic.com"]
    end
  end

  context "with official anthropic gem loaded" do
    # Create a mock base class that the interceptor can properly inherit from
    let(:mock_base_class) do
      Class.new do
        def request(**)
          # rubocop:disable Style/OpenStructUse
          OpenStruct.new(
            status: 200,
            body: { content: [{ text: "Hello from Anthropic" }] },
            headers: { "content-type" => "application/json" }
          )
          # rubocop:enable Style/OpenStructUse
        end
      end
    end

    let(:mock_base_client) do
      Class.new(mock_base_class) do
        include Coolhand::AnthropicInterceptor::RequestInterceptor

        attr_accessor :base_url

        def initialize
          @base_url = "https://api.anthropic.com"
        end
      end.new
    end

    before do
      # Mock official anthropic gem being present
      allow(Coolhand).to receive(:anthropic_gem_loaded?).and_return(true)
      stub_const("Anthropic::Internal", Module.new)

      # Reset interceptors
      Coolhand::FaradayInterceptor.unpatch!
      Coolhand::AnthropicInterceptor.instance_variable_set(:@patched, false)

      # Mock BaseInterceptor methods
      allow(Coolhand::BaseInterceptor).to receive_messages(clean_request_headers: {}, extract_response_data: {})
      allow(Coolhand::BaseInterceptor).to receive(:send_complete_request_log)

      # Mock the require calls to avoid loading real gem files
      allow(Coolhand::AnthropicInterceptor).to receive(:require)
        .with("anthropic/internal/transport/base_client")
      allow(Coolhand::AnthropicInterceptor).to receive(:require)
        .with("anthropic/helpers/streaming/message_stream")

      # Mock the prepend calls
      # First stub the nested modules
      transport_module = Module.new
      streaming_module = Module.new
      stub_const("Anthropic::Internal::Transport", transport_module)
      stub_const("Anthropic::Streaming", streaming_module)

      # Then create string-based doubles to avoid constant lookup
      # rubocop:disable RSpec/VerifiedDoubleReference
      mock_base_client_class = class_double("Anthropic::Internal::Transport::BaseClient")
      mock_stream_class = class_double("Anthropic::Streaming::MessageStream")
      # rubocop:enable RSpec/VerifiedDoubleReference
      stub_const("Anthropic::Internal::Transport::BaseClient", mock_base_client_class)
      stub_const("Anthropic::Streaming::MessageStream", mock_stream_class)
      allow(mock_base_client_class).to receive(:prepend)
      allow(mock_stream_class).to receive(:prepend)

      # Patch both interceptors as the configure method would
      Coolhand::FaradayInterceptor.patch!
      Coolhand::AnthropicInterceptor.patch!
    end

    after do
      Coolhand::FaradayInterceptor.unpatch!
      Coolhand::AnthropicInterceptor.instance_variable_set(:@patched, false)
    end

    it "prevents duplicate logging when AnthropicInterceptor and FaradayInterceptor both try to intercept" do
      request_params = {
        method: :post,
        path: "/v1/messages",
        body: { model: "claude-3-sonnet", messages: [{ role: "user", content: "Hello" }] },
        headers: { "Content-Type" => "application/json" }
      }

      # Make a request through the AnthropicInterceptor
      mock_base_client.request(**request_params)

      # Should only log once via AnthropicInterceptor, not twice
      expect(Coolhand::BaseInterceptor).to have_received(:send_complete_request_log).once
    end

    it "sets and clears thread-local suppression flag correctly" do
      request_params = {
        method: :post,
        path: "/v1/messages",
        body: { model: "claude-3-sonnet", messages: [{ role: "user", content: "Hello" }] },
        headers: { "Content-Type" => "application/json" }
      }

      # Verify flag is initially nil/false
      expect(Thread.current[:coolhand_disable_faraday]).to be_falsy

      mock_base_client.request(**request_params)

      # Verify flag is cleared after request
      expect(Thread.current[:coolhand_disable_faraday]).to be false
    end

    it "handles errors and still clears suppression flag" do
      request_params = {
        method: :post,
        path: "/v1/messages",
        body: { model: "claude-3-sonnet", messages: [{ role: "user", content: "Hello" }] },
        headers: { "Content-Type" => "application/json" }
      }

      # Make the base class request method fail
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(mock_base_class).to receive(:request).and_raise(StandardError.new("API Error"))
      # rubocop:enable RSpec/AnyInstance

      expect { mock_base_client.request(**request_params) }.to raise_error(StandardError, "API Error")

      # Verify flag is still cleared even after error
      expect(Thread.current[:coolhand_disable_faraday]).to be false
    end
  end

  context "with ruby-anthropic gem (Faraday-based requests)" do
    let(:faraday_connection) do
      Faraday.new("https://api.anthropic.com") do |builder|
        builder.adapter :test do |stub|
          stub.post("/v1/messages") do
            [200, { "Content-Type" => "application/json" }, '{"content":[{"text":"Hello from ruby-anthropic"}]}']
          end
        end
      end
    end

    before do
      # Mock ruby-anthropic gem being present (no Anthropic::Internal)
      allow(Coolhand).to receive(:anthropic_gem_loaded?).and_return(true)
      hide_const("Anthropic::Internal") if defined?(Anthropic::Internal)

      # Reset interceptors
      Coolhand::FaradayInterceptor.unpatch!
      Coolhand::AnthropicInterceptor.instance_variable_set(:@patched, false)

      # Only patch FaradayInterceptor for ruby-anthropic
      Coolhand::FaradayInterceptor.patch!
    end

    after do
      Coolhand::FaradayInterceptor.unpatch!
    end

    it "logs requests only once through FaradayInterceptor" do
      # Make a Faraday request that would go through ruby-anthropic
      faraday_connection.post("/v1/messages", { model: "claude-3-sonnet", messages: [] }.to_json)

      # Give thread a chance to run
      sleep 0.1

      # Should log exactly once via FaradayInterceptor
      expect(api_service_instance).to have_received(:send_llm_request_log).once
    end

    it "does not attempt to use AnthropicInterceptor for ruby-anthropic" do
      expect(Coolhand::AnthropicInterceptor.patched?).to be false

      # Make a request - should only go through Faraday
      faraday_connection.post("/v1/messages", { model: "claude-3-sonnet", messages: [] }.to_json)

      # Give thread a chance to run
      sleep 0.1

      # Verify only FaradayInterceptor was used
      expect(api_service_instance).to have_received(:send_llm_request_log).once
    end
  end

  context "when using concurrent requests" do
    let(:thread_mock_base_class) do
      Class.new do
        def request(**)
          # rubocop:disable Style/OpenStructUse
          OpenStruct.new(status: 200, body: {}, headers: {})
          # rubocop:enable Style/OpenStructUse
        end
      end
    end

    let(:first_mock_client) do
      Class.new(thread_mock_base_class) do
        include Coolhand::AnthropicInterceptor::RequestInterceptor

        attr_accessor :base_url

        def initialize
          @base_url = "https://api.anthropic.com"
        end
      end.new
    end

    let(:second_mock_client) do
      Class.new(thread_mock_base_class) do
        include Coolhand::AnthropicInterceptor::RequestInterceptor

        attr_accessor :base_url

        def initialize
          @base_url = "https://api.anthropic.com"
        end
      end.new
    end

    before do
      allow(Coolhand::BaseInterceptor).to receive_messages(clean_request_headers: {}, extract_response_data: {})
      allow(Coolhand::BaseInterceptor).to receive(:send_complete_request_log)
    end

    it "maintains thread-local isolation between concurrent requests" do
      threads = []
      thread_flags = {}

      request_params = {
        method: :post,
        path: "/v1/messages",
        body: { model: "claude-3-sonnet", messages: [{ role: "user", content: "Hello" }] },
        headers: { "Content-Type" => "application/json" }
      }

      # Start concurrent requests in different threads
      threads << Thread.new do
        first_mock_client.request(**request_params)
        thread_flags[:thread1] = Thread.current[:coolhand_disable_faraday]
      end

      threads << Thread.new do
        second_mock_client.request(**request_params)
        thread_flags[:thread2] = Thread.current[:coolhand_disable_faraday]
      end

      threads.each(&:join)

      # Both threads should have cleared their flags independently
      expect(thread_flags[:thread1]).to be false
      expect(thread_flags[:thread2]).to be false
    end
  end
end
# rubocop:enable RSpec/DescribeClass
