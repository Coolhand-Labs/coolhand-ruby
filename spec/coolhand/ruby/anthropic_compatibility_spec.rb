# frozen_string_literal: true

require "spec_helper"

# Simplified compatibility test for CI/CD pipeline
# This test verifies that coolhand-ruby works with different versions of the Anthropic gem
RSpec.describe "Anthropic Compatibility (CI)", :integration do
  before do
    # Set up fresh environment for each test
    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["api.anthropic.com"]
    end

    # Mock API service to avoid real network calls
    allow(Coolhand::Ruby::ApiService).to receive(:new).and_return(api_service_double)
    allow(api_service_double).to receive(:send_llm_request_log)
    allow(Coolhand).to receive(:log)
  end

  after do
    # Clean up patches and thread state
    Coolhand::Ruby::AnthropicInterceptor.unpatch! if Coolhand::Ruby::AnthropicInterceptor.patched?
    Thread.current[:coolhand_current_request_id] = nil
    Thread.current[:coolhand_streaming_request] = nil
  end

  let(:api_service_double) { instance_double(Coolhand::Ruby::ApiService) }

  context "when Anthropic gem is available" do
    before do
      skip "Anthropic gem not available" unless anthropic_gem_available?

      # Ensure we have a clean state
      Coolhand::Ruby::AnthropicInterceptor.unpatch! if Coolhand::Ruby::AnthropicInterceptor.patched?
    end

    it "successfully patches the Anthropic client" do
      require "anthropic"

      expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true

      # Verify that the right classes were patched
      if defined?(Anthropic::Internal::Transport::BaseClient)
        expect(Anthropic::Internal::Transport::BaseClient.ancestors).to include(
          Coolhand::Ruby::AnthropicInterceptor::RequestInterceptor
        )
      end
    end

    it "intercepts Anthropic API calls without making real requests" do
      require "anthropic"

      # Apply patches
      Coolhand::Ruby::AnthropicInterceptor.patch!

      # Create real Anthropic client
      client = Anthropic::Client.new

      # Mock the HTTP layer to prevent real API calls
      mock_faraday_response = instance_double(Faraday::Response)
      allow(mock_faraday_response).to receive_messages(status: 200, body: {
        "id" => "msg_test_123",
        "type" => "message",
        "role" => "assistant",
        "content" => [{ "type" => "text", "text" => "Hello from test!" }],
        "model" => "claude-3-haiku-20240307",
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
      })

      # Mock Faraday connection to return our mock response
      allow_any_instance_of(Faraday::Connection).to receive(:post).and_return(mock_faraday_response)

      # Make a request that should be intercepted
      expect do
        response = client.messages(
          model: "claude-3-haiku-20240307",
          max_tokens: 100,
          messages: [{ role: "user", content: "Hello!" }]
        )
        expect(response).to be_present
      end.not_to raise_error

      # Verify our interceptor logged the request
      expect(api_service_double).to have_received(:send_llm_request_log).with(
        hash_including(
          raw_request: hash_including(
            url: a_string_including("api.anthropic.com"),
            method: "post",
            is_streaming: false
          )
        )
      )

      # Verify request ID was set
      expect(Thread.current[:coolhand_current_request_id]).to be_a(String)
    end

    it "handles missing MessageStream class gracefully" do
      require "anthropic"

      Coolhand::Ruby::AnthropicInterceptor.patch!

      # Test should pass regardless of whether MessageStream is available in this version
      if defined?(Anthropic::Streaming::MessageStream)
        expect(Anthropic::Streaming::MessageStream.ancestors).to include(
          Coolhand::Ruby::AnthropicInterceptor::MessageStreamInterceptor
        )
      else
        # MessageStream not available in this version - that's fine
        expect(true).to be true
      end
    end

    it "can be unpatched and re-patched" do
      require "anthropic"

      # Initial patch
      Coolhand::Ruby::AnthropicInterceptor.patch!
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true

      # Unpatch
      Coolhand::Ruby::AnthropicInterceptor.unpatch!
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be false

      # Re-patch
      expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
    end

    it "prevents double-patching" do
      require "anthropic"

      # First patch
      Coolhand::Ruby::AnthropicInterceptor.patch!
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true

      # Second patch attempt should be safe
      expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be true
    end
  end

  context "when Anthropic gem is not available" do
    before do
      skip "Anthropic gem is available" if anthropic_gem_available?
    end

    it "gracefully handles missing gem" do
      expect { Coolhand::Ruby::AnthropicInterceptor.patch! }.not_to raise_error
      expect(Coolhand::Ruby::AnthropicInterceptor.patched?).to be false
    end
  end

  private

  def anthropic_gem_available?
    require "anthropic"
    defined?(Anthropic)
  rescue LoadError
    false
  end
end
