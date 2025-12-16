# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Ruby::AnthropicInterceptor do
  before do
    # Reset patched state before each test
    described_class.instance_variable_set(:@patched, false)
    allow(Coolhand).to receive(:log)
  end

  after do
    # Clean up after each test
    described_class.instance_variable_set(:@patched, false)
  end

  describe ".patch!" do
    context "when no Anthropic constant is defined" do
      before do
        # Hide Anthropic constant for this test
        hide_const("Anthropic") if defined?(Anthropic)
      end

      it "returns early without patching" do
        expect { described_class.patch! }.not_to(change(described_class, :patched?))
        expect(described_class.patched?).to be false
      end
    end

    context "when both anthropic gems are installed" do
      before do
        # Mock both gems being installed
        allow(described_class).to receive(:both_gems_installed?).and_return(true)

        # Ensure Anthropic constant exists for the test
        stub_const("Anthropic", Module.new) unless defined?(Anthropic)
      end

      it "shows warning message regardless of silent mode" do
        expect(described_class).to receive(:puts).with(
          "COOLHAND: ⚠️  Warning: Both 'anthropic' and 'ruby-anthropic' gems are installed. " \
          "Coolhand will only monitor ruby-anthropic (Faraday-based) requests. " \
          "Official anthropic gem monitoring has been disabled."
        )

        described_class.patch!
      end

      it "marks as patched and returns early" do
        allow(described_class).to receive(:puts) # Silence warning for this test

        described_class.patch!

        expect(described_class.patched?).to be true
      end

      it "does not attempt to patch official anthropic gem" do
        allow(described_class).to receive(:puts) # Silence warning for this test

        # Mock the official anthropic gem being present
        stub_const("Anthropic::Internal", Module.new)
        expect(described_class).not_to receive(:require).with("anthropic/internal/transport/base_client")

        described_class.patch!
      end
    end

    context "when only official anthropic gem is installed" do
      before do
        allow(described_class).to receive(:both_gems_installed?).and_return(false)

        # Mock official anthropic gem
        stub_const("Anthropic", Module.new)
        stub_const("Anthropic::Internal", Module.new)
        stub_const("Anthropic::Internal::Transport", Module.new)
        stub_const("Anthropic::Internal::Transport::BaseClient", Class.new)
        stub_const("Anthropic::Streaming", Module.new)
        stub_const("Anthropic::Streaming::MessageStream", Class.new)

        allow(described_class).to receive(:require).with("anthropic/internal/transport/base_client")
        allow(described_class).to receive(:require).with("anthropic/helpers/streaming/message_stream")
        allow(Anthropic::Internal::Transport::BaseClient).to receive(:prepend)
        allow(Anthropic::Streaming::MessageStream).to receive(:prepend)
      end

      it "patches the official anthropic gem" do
        described_class.patch!

        expect(described_class).to have_received(:require).with("anthropic/internal/transport/base_client")
        expect(Anthropic::Internal::Transport::BaseClient).to have_received(:prepend)
          .with(described_class::RequestInterceptor)
        expect(described_class.patched?).to be true
      end

      it "patches MessageStream for streaming support" do
        described_class.patch!

        expect(Anthropic::Streaming::MessageStream).to have_received(:prepend)
          .with(described_class::MessageStreamInterceptor)
      end
    end

    context "when only ruby-anthropic gem is installed" do
      before do
        allow(described_class).to receive(:both_gems_installed?).and_return(false)

        # Mock ruby-anthropic gem (no Anthropic::Internal)
        stub_const("Anthropic", Module.new)
        # Ensure Anthropic::Internal is not defined for this test
        hide_const("Anthropic::Internal") if defined?(Anthropic::Internal)
      end

      it "logs that ruby-anthropic is detected" do
        described_class.patch!

        expect(Coolhand).to have_received(:log).with("✅ ruby-anthropic detected, using Faraday interceptor")
        expect(described_class.patched?).to be true
      end

      it "does not attempt to patch official anthropic components" do
        expect(described_class).not_to receive(:require).with("anthropic/internal/transport/base_client")

        described_class.patch!
      end
    end

    context "when already patched" do
      before do
        described_class.instance_variable_set(:@patched, true)
      end

      it "returns early without doing anything" do
        expect(described_class).not_to receive(:both_gems_installed?)

        described_class.patch!
      end
    end
  end

  describe ".unpatch!" do
    it "marks as unpatched" do
      described_class.instance_variable_set(:@patched, true)

      described_class.unpatch!

      expect(described_class.patched?).to be false
      expect(Coolhand).to have_received(:log)
        .with("⚠️  Anthropic interceptor unpatch requested (not fully implemented)")
    end
  end

  describe ".both_gems_installed?" do
    context "when both gems are in loaded specs" do
      before do
        loaded_specs = {
          "anthropic" => instance_double(Gem::Specification, name: "anthropic"),
          "ruby-anthropic" => instance_double(Gem::Specification, name: "ruby-anthropic"),
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns true" do
        expect(described_class).to be_both_gems_installed
      end
    end

    context "when only anthropic gem is loaded" do
      before do
        loaded_specs = {
          "anthropic" => instance_double(Gem::Specification, name: "anthropic"),
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns false" do
        expect(described_class).not_to be_both_gems_installed
      end
    end

    context "when only ruby-anthropic gem is loaded" do
      before do
        loaded_specs = {
          "ruby-anthropic" => instance_double(Gem::Specification, name: "ruby-anthropic"),
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns false" do
        expect(described_class).not_to be_both_gems_installed
      end
    end

    context "when neither gem is loaded" do
      before do
        loaded_specs = {
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns false" do
        expect(described_class).not_to be_both_gems_installed
      end
    end
  end

  describe ".patched?" do
    it "returns false by default" do
      expect(described_class.patched?).to be false
    end

    it "returns true when @patched is set" do
      described_class.instance_variable_set(:@patched, true)
      expect(described_class.patched?).to be true
    end
  end

  describe "RequestInterceptor" do
    let(:mock_base_class) do
      Class.new do
        def request(**)
          # Mock response object
          # rubocop:disable Style/OpenStructUse
          OpenStruct.new(
            status: 200,
            body: { "choices" => [{ "message" => { "content" => "Hello" } }] },
            headers: { "content-type" => "application/json" }
          )
          # rubocop:enable Style/OpenStructUse
        end
      end
    end

    let(:request_interceptor_instance) do
      Class.new(mock_base_class) do
        include Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor

        attr_accessor :base_url

        def initialize
          @base_url = "https://api.anthropic.com"
        end
      end.new
    end

    describe "#request" do
      let(:request_params) do
        {
          method: :post,
          path: "/v1/messages",
          body: { model: "claude-3-sonnet", messages: [{ role: "user", content: "Hello" }] },
          headers: { "Content-Type" => "application/json" }
        }
      end

      before do
        # Mock BaseInterceptor methods
        allow(Coolhand::Ruby::BaseInterceptor).to receive_messages(clean_request_headers: {}, extract_response_data: {})
        allow(Coolhand::Ruby::BaseInterceptor).to receive(:send_complete_request_log)
      end

      it "sets and clears thread-local Faraday suppression flag" do
        # Reset thread-local state for clean test
        Thread.current[:coolhand_disable_faraday] = nil

        expect(Thread.current[:coolhand_disable_faraday]).to be_nil

        request_interceptor_instance.request(**request_params)

        # Should be cleared after request
        expect(Thread.current[:coolhand_disable_faraday]).to be false
      end

      it "temporarily disables Faraday interception during request" do
        flag_during_request = nil

        # Use a spy to capture the flag state when the base method is called
        original_request = mock_base_class.instance_method(:request)
        # rubocop:disable RSpec/AnyInstance
        allow_any_instance_of(mock_base_class).to receive(:request) do |instance, **args|
          flag_during_request = Thread.current[:coolhand_disable_faraday]
          original_request.bind_call(instance, **args)
        end
        # rubocop:enable RSpec/AnyInstance

        request_interceptor_instance.request(**request_params)

        expect(flag_during_request).to be true
      end

      it "stores request ID in thread-local storage" do
        request_interceptor_instance.request(**request_params)

        expect(Thread.current[:coolhand_current_request_id]).to match(/\A[a-f0-9]{32}\z/)
      end

      it "logs complete request data for non-streaming requests" do
        request_interceptor_instance.request(**request_params)

        expect(Coolhand::Ruby::BaseInterceptor).to have_received(:send_complete_request_log)
          .with(hash_including(
            request_id: anything,
            method: :post,
            url: "https://api.anthropic.com/v1/messages",
            start_time: anything,
            end_time: anything,
            duration_ms: anything,
            is_streaming: false
          ))
      end

      it "stores streaming request metadata for streaming requests" do
        streaming_params = request_params.merge(body: request_params[:body].merge(stream: true))

        request_interceptor_instance.request(**streaming_params)

        streaming_request = Thread.current[:coolhand_streaming_request]
        expect(streaming_request).not_to be_nil
        expect(streaming_request[:is_streaming]).to be true
        expect(streaming_request[:request_id]).to match(/\A[a-f0-9]{32}\z/)
      end

      context "when an error occurs" do
        before do
          # rubocop:disable RSpec/AnyInstance
          allow_any_instance_of(mock_base_class).to receive(:request).and_raise(StandardError.new("API Error"))
          # rubocop:enable RSpec/AnyInstance
        end

        it "still clears the thread-local flag" do
          expect { request_interceptor_instance.request(**request_params) }.to raise_error(StandardError, "API Error")

          expect(Thread.current[:coolhand_disable_faraday]).to be false
        end

        it "logs the error response" do
          expect { request_interceptor_instance.request(**request_params) }.to raise_error(StandardError)

          expect(Coolhand::Ruby::BaseInterceptor).to have_received(:send_complete_request_log)
            .with(hash_including(
              response_body: {
                error: {
                  message: "API Error",
                  class: "StandardError"
                }
              }
            ))
        end
      end
    end

    describe "#streaming_request?" do
      it "detects streaming from request body stream parameter" do
        body = { stream: true }
        headers = {}

        result = request_interceptor_instance.send(:streaming_request?, body, headers)
        expect(result).to be true
      end

      it "detects streaming from Accept header" do
        body = {}
        headers = { "Accept" => "text/event-stream" }

        result = request_interceptor_instance.send(:streaming_request?, body, headers)
        expect(result).to be true
      end

      it "returns false for non-streaming requests" do
        body = { stream: false }
        headers = { "Accept" => "application/json" }

        result = request_interceptor_instance.send(:streaming_request?, body, headers)
        expect(result).to be false
      end
    end
  end

  describe "MessageStreamInterceptor" do
    let(:mock_stream_class) do
      Class.new do
        def accumulated_message
          # rubocop:disable Style/OpenStructUse
          OpenStruct.new(
            content: [{ text: "Generated response" }],
            role: "assistant"
          )
          # rubocop:enable Style/OpenStructUse
        end
      end
    end

    let(:message_stream_instance) do
      Class.new(mock_stream_class) do
        include Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor
      end.new
    end

    describe "#accumulated_message" do
      context "when streaming request metadata exists" do
        before do
          Thread.current[:coolhand_streaming_request] = {
            request_id: "test-request-id",
            method: :post,
            url: "https://api.anthropic.com/v1/messages",
            request_headers: {},
            request_body: {},
            start_time: Time.now - 1,
            end_time: Time.now,
            duration_ms: 1000,
            is_streaming: true
          }

          allow(Coolhand::Ruby::BaseInterceptor).to receive(:extract_response_data).and_return({})
          allow(Coolhand::Ruby::BaseInterceptor).to receive(:send_complete_request_log)
        end

        it "logs streaming completion and clears thread-local data" do
          message_stream_instance.accumulated_message

          expect(Coolhand::Ruby::BaseInterceptor).to have_received(:send_complete_request_log)
            .with(hash_including(
              request_id: "test-request-id",
              is_streaming: true
            ))

          expect(Thread.current[:coolhand_streaming_request]).to be_nil
        end
      end

      context "when no streaming request metadata exists" do
        before do
          Thread.current[:coolhand_streaming_request] = nil
          allow(Coolhand::Ruby::BaseInterceptor).to receive(:send_complete_request_log)
        end

        it "does not attempt to log completion" do
          message_stream_instance.accumulated_message

          expect(Coolhand::Ruby::BaseInterceptor).not_to have_received(:send_complete_request_log)
        end
      end
    end
  end
end
