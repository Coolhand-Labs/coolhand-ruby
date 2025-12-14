# frozen_string_literal: true

require "spec_helper"

# This test file demonstrates integration testing with specific Anthropic gem versions
# To run these tests with different versions, use:
# ANTHROPIC_VERSION=1.8.0 bundle exec rspec spec/coolhand/ruby/anthropic_version_integration_spec.rb
# ANTHROPIC_VERSION=1.16.0 bundle exec rspec spec/coolhand/ruby/anthropic_version_integration_spec.rb

RSpec.describe "Anthropic Interceptor Version Integration", :integration do
  let(:api_service_instance) { instance_double(Coolhand::Ruby::ApiService) }
  let(:api_service_class) { class_double(Coolhand::Ruby::ApiService).as_stubbed_const }
  let(:test_version) { ENV["ANTHROPIC_VERSION"] || "1.16.0" }

  before do
    allow(api_service_class).to receive(:new).and_return(api_service_instance)
    allow(api_service_instance).to receive(:send_llm_request_log)
    allow(Coolhand).to receive(:log)

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["api.anthropic.com"]
    end

    # Clean up any previous patches
    Coolhand::Ruby::AnthropicInterceptor.unpatch!
  end

  after do
    Coolhand::Ruby::AnthropicInterceptor.unpatch!
    Thread.current[:coolhand_current_request_id] = nil
    Thread.current[:coolhand_streaming_request] = nil
  end

  describe "with actual Anthropic gem" do
    # Skip these tests if Anthropic gem is not available
    before do
      skip "Anthropic gem not available" unless defined?(Anthropic)

      # Verify we're testing with the expected version
      if defined?(Anthropic::VERSION) && test_version != "any"
        unless Anthropic::VERSION.start_with?(test_version)
          skip "Expected Anthropic v#{test_version}, got v#{Anthropic::VERSION}"
        end
      end
    end

    describe "patching behavior" do
      it "successfully patches with version #{ENV['ANTHROPIC_VERSION'] || 'current'}" do
        expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
        expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
      end

      it "patches BaseClient correctly" do
        Coolhand::Ruby::AnthropicInterceptor.patch!

        # Verify the interceptor module is in the ancestor chain
        expect(Anthropic::Internal::Transport::BaseClient.ancestors).to include(
          Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor
        )
      end

      it "patches MessageStream correctly when available" do
        skip "MessageStream not available in this version" unless defined?(Anthropic::Streaming::MessageStream)

        Coolhand::Ruby::AnthropicInterceptor.patch!

        expect(Anthropic::Streaming::MessageStream.ancestors).to include(
          Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor
        )
      end
    end

    describe "request interception" do
      let(:mock_client) { instance_double(Anthropic::Internal::Transport::BaseClient) }
      let(:mock_response) do
        double("response",
          content: "Hello!",
          usage: double(input_tokens: 10, output_tokens: 5),
          model: "claude-3-haiku-20240307",
          id: "msg_123",
          stop_reason: "end_turn",
          role: "assistant")
      end

      before do
        Coolhand::Ruby::AnthropicInterceptor.patch!

        # Mock the base_url instance variable
        allow(mock_client).to receive(:instance_variable_get).with(:@base_url).and_return("https://api.anthropic.com")

        # Extend the mock with our interceptor module
        mock_client.extend(Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor)
      end

      it "intercepts and logs non-streaming requests" do
        allow(mock_client).to receive_messages(super: mock_response, streaming_request?: false,
          extract_response_headers: {})

        result = mock_client.request(
          method: :post,
          path: "/v1/messages",
          body: { model: "claude-3-haiku-20240307", messages: [{ role: "user", content: "Hello" }] },
          headers: { "Content-Type" => "application/json" }
        )

        expect(result).to eq(mock_response)
        expect(api_service_instance).to have_received(:send_llm_request_log).with(
          a_hash_including(
            raw_request: a_hash_including(
              method: "post",
              url: "https://api.anthropic.com/v1/messages",
              is_streaming: false
            )
          )
        )
      end

      it "handles streaming request metadata properly" do
        allow(mock_client).to receive_messages(super: mock_response, streaming_request?: true,
          extract_response_headers: {})

        mock_client.request(
          method: :post,
          path: "/v1/messages",
          body: { model: "claude-3-haiku-20240307", stream: true },
          headers: { "Content-Type" => "application/json" }
        )

        # Should store metadata for streaming completion
        expect(Thread.current[:coolhand_streaming_request]).to be_a(Hash)
        expect(Thread.current[:coolhand_streaming_request][:is_streaming]).to be true

        # Should not send log immediately for streaming
        expect(api_service_instance).not_to have_received(:send_llm_request_log)
      end
    end

    describe "version-specific behavior" do
      before do
        Coolhand::Ruby::AnthropicInterceptor.patch!
      end

      case ENV.fetch("ANTHROPIC_VERSION", nil)
      when /^1\.8/
        it "works with Anthropic v1.8.x API structure" do
          # Test specific to v1.8 behavior
          expect(defined?(Anthropic::Internal::Transport::BaseClient)).to be_truthy

          # v1.8 might have different response structure
          expect { Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor }.not_to raise_error
        end

      when /^1\.16/
        it "works with Anthropic v1.16.x API structure" do
          # Test specific to v1.16 behavior
          expect(defined?(Anthropic::Internal::Transport::BaseClient)).to be_truthy
          expect(defined?(Anthropic::Streaming::MessageStream)).to be_truthy

          # v1.16 should have both regular and streaming support
          expect { Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor }.not_to raise_error
        end

      else
        it "works with current Anthropic gem version" do
          # Generic test that should work with any version
          expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
          expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
        end
      end
    end

    describe "streaming response handling" do
      let(:mock_stream) { instance_double(MessageStreamInstance) }
      let(:accumulated_message) do
        double("message",
          content: "Hello world!",
          usage: double(input_tokens: 10, output_tokens: 15),
          model: "claude-3-haiku-20240307",
          id: "msg_456",
          stop_reason: "end_turn")
      end

      before do
        skip "MessageStream not available in this version" unless defined?(Anthropic::Streaming::MessageStream)

        Coolhand::Ruby::AnthropicInterceptor.patch!

        # Set up streaming metadata
        Thread.current[:coolhand_streaming_request] = {
          request_id: "test-stream-id",
          method: :post,
          url: "https://api.anthropic.com/v1/messages",
          request_headers: { "Content-Type" => "application/json" },
          request_body: { model: "claude-3-haiku-20240307", stream: true },
          start_time: Time.now - 1,
          end_time: Time.now,
          duration_ms: 1500.0,
          is_streaming: true
        }

        # Extend mock with interceptor
        mock_stream.extend(Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor)
        allow(mock_stream).to receive(:super).and_return(accumulated_message)
      end

      it "logs completion when accumulated_message is called" do
        result = mock_stream.accumulated_message

        expect(result).to eq(accumulated_message)
        expect(api_service_instance).to have_received(:send_llm_request_log).with(
          a_hash_including(
            raw_request: a_hash_including(
              request_id: "test-stream-id",
              is_streaming: true
            )
          )
        )
      end
    end
  end

  describe "version compatibility matrix" do
    let(:versions_to_test) { %w[1.8.0 1.16.0] }

    it "documents expected compatibility" do
      # This test documents which versions we expect to work with
      expect(versions_to_test).to all(match(/\d+\.\d+\.\d+/))

      # You can extend this to test specific version behaviors
      versions_to_test.each do |version|
        expect(version).to match(/^1\.(8|16)\./)
      end
    end
  end
end
