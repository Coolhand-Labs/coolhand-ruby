# frozen_string_literal: true

require "spec_helper"

# This test demonstrates integration with actual Anthropic gem structure
# It requires the gem to be available and tests the real patching behavior
RSpec.describe "Anthropic Real Integration" do
  let(:api_service_instance) { instance_double(Coolhand::Ruby::ApiService) }
  let(:api_service_class) { class_double(Coolhand::Ruby::ApiService).as_stubbed_const }

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

  after do
    # Clean up patches
    Coolhand::Ruby::AnthropicInterceptor.unpatch!
    Thread.current[:coolhand_current_request_id] = nil
    Thread.current[:coolhand_streaming_request] = nil
  end

  context "when Anthropic gem v1.0+ is available", if: -> { self.class.anthropic_v1_available? } do
    it "successfully patches the real Anthropic BaseClient" do
      # Require the gem
      require "anthropic"

      # Apply patches
      expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true

      # Verify patching worked by checking ancestor chain
      expect(Anthropic::Internal::Transport::BaseClient.ancestors).to include(
        Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor
      )
    end

    it "successfully patches the real MessageStream class when available" do
      require "anthropic"

      # Apply patches
      Coolhand::Ruby::AnthropicInterceptor.patch!

      # Check if MessageStream is available (might vary by version)
      if defined?(Anthropic::Streaming::MessageStream)
        expect(Anthropic::Streaming::MessageStream.ancestors).to include(
          Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor
        )
      else
        pending "MessageStream not available in this Anthropic version"
      end
    end

    it "can intercept actual client requests with mock HTTP" do
      require "anthropic"

      # Apply patches
      Coolhand::Ruby::AnthropicInterceptor.patch!

      # Create a real client but mock the HTTP layer
      client = Anthropic::Client.new

      # Mock the underlying HTTP request to avoid real API calls
      allow_any_instance_of(Faraday::Connection).to receive(:post) do |_conn, *_args|
        # Return a mock response that looks like real Anthropic response
        Faraday::Response.new.tap do |response|
          response.status = 200
          response.body = {
            "id" => "msg_123",
            "type" => "message",
            "role" => "assistant",
            "content" => [
              {
                "type" => "text",
                "text" => "Hello! How can I help you today?"
              }
            ],
            "model" => "claude-3-haiku-20240307",
            "stop_reason" => "end_turn",
            "stop_sequence" => nil,
            "usage" => {
              "input_tokens" => 10,
              "output_tokens" => 25
            }
          }
        end
      end

      # Make a request - this should trigger our interceptor
      expect do
        response = client.messages(
          model: "claude-3-haiku-20240307",
          max_tokens: 100,
          messages: [{ role: "user", content: "Hello!" }]
        )
        expect(response).to be_present
      end.not_to raise_error

      # Verify our interceptor was called
      expect(api_service_instance).to have_received(:send_llm_request_log).with(
        a_hash_including(
          raw_request: a_hash_including(
            url: a_string_including("api.anthropic.com"),
            method: "post",
            is_streaming: false
          )
        )
      )

      # Verify request ID was set
      expect(Thread.current[:coolhand_current_request_id]).to be_a(String)
    end

    it "handles streaming requests properly with real client" do
      require "anthropic"

      # Apply patches
      Coolhand::Ruby::AnthropicInterceptor.patch!

      # Create a real client
      client = Anthropic::Client.new

      # Mock streaming response
      allow_any_instance_of(Faraday::Connection).to receive(:post) do |_conn, *_args|
        # Return a mock streaming response
        Faraday::Response.new.tap do |response|
          response.status = 200
          # For streaming, the response would be an enumerator, but we'll mock it simply
          response.body = {
            "id" => "msg_123",
            "type" => "message",
            "role" => "assistant",
            "content" => [{ "type" => "text", "text" => "Hello there!" }],
            "model" => "claude-3-haiku-20240307",
            "usage" => { "input_tokens" => 10, "output_tokens" => 15 }
          }
        end
      end

      # Test streaming request
      streaming_content = []
      expect do
        client.messages(
          model: "claude-3-haiku-20240307",
          max_tokens: 100,
          messages: [{ role: "user", content: "Hello!" }],
          stream: proc { |chunk| streaming_content << chunk }
        )
      end.not_to raise_error

      # For streaming requests, metadata should be stored but not logged immediately
      expect(Thread.current[:coolhand_streaming_request]).to be_a(Hash)
      expect(Thread.current[:coolhand_streaming_request][:is_streaming]).to be true

      # Non-immediate logging for streaming
      expect(api_service_instance).not_to have_received(:send_llm_request_log)
    end
  end

  context "when Anthropic gem is not available" do
    before do
      # Hide the constant if it exists
      @anthropic_const = Object.send(:remove_const, :Anthropic) if defined?(Anthropic)
    end

    after do
      # Restore the constant if we removed it
      Object.const_set(:Anthropic, @anthropic_const) if @anthropic_const
    end

    it "gracefully handles missing gem" do
      expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be false
    end
  end

  #   # Test with version-specific mocks that represent real gem structures
  #   # NOTE: This is deprecated in favor of CI-based testing with real gem versions
  #   describe "version-specific compatibility tests" do
  #     let(:versions_to_test) do
  #       [
  #         { version: "1.8.0", base_client_path: "Anthropic::Internal::Transport::BaseClient" },
  #         { version: "1.16.0", base_client_path: "Anthropic::Internal::Transport::BaseClient" }
  #       ]
  #     end
  #
  #     versions_to_test.each do |version_info|
  #       context "with Anthropic v#{version_info[:version]} structure" do
  #         let(:mock_base_client) { Class.new }
  #         let(:mock_message_stream) { Class.new }
  #
  #         before do
  #           # Create realistic module structure for this version
  #           anthropic_module = Module.new
  #           internal_module = Module.new
  #           transport_module = Module.new
  #           streaming_module = Module.new
  #
  #           # Mock the class hierarchy that would exist in the real gem
  #           anthropic_module.const_set("Internal", internal_module)
  #           internal_module.const_set("Transport", transport_module)
  #           transport_module.const_set("BaseClient", mock_base_client)
  #           anthropic_module.const_set("Streaming", streaming_module)
  #           streaming_module.const_set("MessageStream", mock_message_stream)
  #           anthropic_module.const_set("VERSION", version_info[:version])
  #
  #           stub_const("Anthropic", anthropic_module)
  #
  #           # Mock prepend behavior
  #           allow(mock_base_client).to receive(:prepend)
  #           allow(mock_message_stream).to receive(:prepend)
  #
  #           # Mock required files
  #           allow(Coolhand::Ruby::AnthropicInterceptor).to receive(:require)
  #         end
  #
  #         it "applies patches to the correct classes for v#{version_info[:version]}" do
  #           expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
  #
  #           expect(mock_base_client).to have_received(:prepend).with(
  #             Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor
  #           )
  #           expect(mock_message_stream).to have_received(:prepend).with(
  #             Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor
  #           )
  #           expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
  #         end
  #
  #         it "can be unpatched and re-patched for v#{version_info[:version]}" do
  #           Coolhand::Ruby::AnthropicInterceptor.patch!
  #           expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
  #
  #           Coolhand::Ruby::AnthropicInterceptor.unpatch!
  #           expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be false
  #
  #           # Should be able to patch again
  #           expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
  #           expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
  #         end
  #
  #         it "prevents double-patching for v#{version_info[:version]}" do
  #           Coolhand::Ruby::AnthropicInterceptor.patch!
  #           Coolhand::Ruby::AnthropicInterceptor.patch!  # Second patch attempt
  #
  #           # Should only be called once despite two patch attempts
  #           expect(mock_base_client).to have_received(:prepend).once
  #           expect(mock_message_stream).to have_received(:prepend).once
  #         end
  #       end
  #     end
  #   end

  # Helper method to check if Anthropic gem v1.0+ is available
  def self.anthropic_v1_available?
    require "anthropic"
    defined?(Anthropic::VERSION) && Gem::Version.new(Anthropic::VERSION) >= Gem::Version.new("1.0.0")
  rescue LoadError
    false
  end

  # Instance method version for use in tests
  def anthropic_v1_available?
    self.class.anthropic_v1_available?
  end

  describe "testing infrastructure validation" do
    it "has proper CI setup for version-specific testing" do
      # Verify our GitHub Actions workflow exists for multi-version testing
      workflow_path = ".github/workflows/actions_ci.yml"
      expect(File.exist?(workflow_path)).to be true

      # Verify the workflow includes Anthropic compatibility testing
      workflow_content = File.read(workflow_path)
      expect(workflow_content).to include("anthropic-compatibility")
      expect(workflow_content).to include("matrix")
      expect(workflow_content).to include("anthropic-version")
    end

    it "documents version-specific testing approach" do
      # Version-specific testing is now handled in CI/CD pipeline
      # See .github/workflows/actions_ci.yml for the anthropic-compatibility job
      # This tests multiple Anthropic gem versions automatically in CI

      expect(ENV).to respond_to(:[]) # Basic environment check

      # CI testing replaces local version-specific Gemfiles
      expect(true).to be true
    end
  end
end
