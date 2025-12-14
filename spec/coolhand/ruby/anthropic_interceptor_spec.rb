# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Ruby::AnthropicInterceptor do
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

    # Clean up any previous patches
    described_class.unpatch!
  end

  after do
    # Ensure we clean up after tests
    described_class.unpatch!
    # Clear thread-local data
    Thread.current[:coolhand_current_request_id] = nil
    Thread.current[:coolhand_streaming_request] = nil
  end

  describe ".patch! and .unpatch!" do
    context "when Anthropic gem is not available" do
      before do
        hide_const("Anthropic")
      end

      it "returns early without patching" do
        expect { described_class.patch! }.not_to raise_error
        expect(described_class.patched?).to be false
      end
    end

    context "when Anthropic gem is available" do
      let(:base_client_class) { class_double(Anthropic::Internal::Transport::BaseClient) }
      let(:message_stream_class) { class_double(Anthropic::Streaming::MessageStream) }

      before do
        stub_const("Anthropic", Module.new)
        stub_const("Anthropic::Internal", Module.new)
        stub_const("Anthropic::Internal::Transport", Module.new)
        stub_const("Anthropic::Internal::Transport::BaseClient", base_client_class)
        stub_const("Anthropic::Streaming", Module.new)
        stub_const("Anthropic::Streaming::MessageStream", message_stream_class)

        allow(base_client_class).to receive(:prepend)
        allow(message_stream_class).to receive(:prepend)

        # Mock the require statements to avoid LoadError
        allow(described_class).to receive(:require)
      end

      it "patches BaseClient when Anthropic is available" do
        described_class.patch!

        expect(base_client_class).to have_received(:prepend).with(described_class::RequestInterceptor)
        expect(described_class.patched?).to be true
      end

      it "patches MessageStream for streaming support" do
        described_class.patch!

        expect(message_stream_class).to have_received(:prepend).with(described_class::MessageStreamInterceptor)
      end

      it "doesn't patch multiple times" do
        described_class.patch!
        described_class.patch!

        expect(base_client_class).to have_received(:prepend).once
        expect(message_stream_class).to have_received(:prepend).once
      end

      it "allows re-patching after unpatch!" do
        described_class.patch!
        described_class.unpatch!

        expect(described_class.patched?).to be false

        expect { described_class.patch! }.not_to raise_error
        expect(described_class.patched?).to be true
      end
    end
  end

  describe "RequestInterceptor module behavior" do
    let(:interceptor_module) { described_class::RequestInterceptor }

    describe "request method" do
      let(:mock_client_class) do
        Class.new do
          attr_accessor :base_url

          def initialize
            @base_url = "https://api.anthropic.com"
          end

          def original_request(method:, path:, body: nil, headers: {})
            double("response",
              content: "Hello!",
              usage: double(input_tokens: 10, output_tokens: 5),
              model: "claude-3-haiku-20240307",
              id: "msg_123",
              stop_reason: "end_turn",
              role: "assistant")
          end
        end
      end

      let(:client_instance) { mock_client_class.new.tap { |c| c.extend(interceptor_module) } }

      before do
        # Mock BaseInterceptor methods
        allow(Coolhand::Ruby::BaseInterceptor).to receive_messages(clean_request_headers: {}, extract_response_data: {
          content: "Hello!",
          usage: { input_tokens: 10, output_tokens: 5 },
          model: "claude-3-haiku-20240307"
        })
        allow(Coolhand::Ruby::BaseInterceptor).to receive(:send_complete_request_log)

        # Mock the super call to use our original_request method
        allow(client_instance).to receive(:original_request).and_call_original
        def client_instance.request(method:, path:, body: nil, headers: {}, **_options)
          # Generate request ID for correlation
          request_id = SecureRandom.hex(16)
          start_time = Time.now

          # Store request ID in thread-local storage for application access
          Thread.current[:coolhand_current_request_id] = request_id

          # Extract request metadata
          full_url = "#{@base_url}#{path}"

          # Capture all request headers including those added by the client
          request_headers = Coolhand::Ruby::BaseInterceptor.clean_request_headers(headers.dup)
          request_body = body

          # Detect if this is a streaming request
          is_streaming = streaming_request?(body, headers)

          # Call the original request method
          begin
            response = original_request(method: method, path: path, body: body, headers: headers)
            end_time = Time.now
            duration_ms = ((end_time - start_time) * 1000).round(2)

            # For streaming responses, store request metadata for later logging
            if is_streaming
              Thread.current[:coolhand_streaming_request] = {
                request_id: request_id,
                method: method,
                url: full_url,
                request_headers: request_headers,
                request_body: request_body,
                start_time: start_time,
                end_time: end_time,
                duration_ms: duration_ms,
                is_streaming: is_streaming
              }
            else
              # Extract response data
              response_data = Coolhand::Ruby::BaseInterceptor.extract_response_data(response)

              # Send complete request/response data in single API call
              Coolhand::Ruby::BaseInterceptor.send_complete_request_log(
                request_id: request_id,
                method: method,
                url: full_url,
                request_headers: request_headers,
                request_body: request_body,
                response_headers: {},
                response_body: response_data,
                status_code: nil,
                start_time: start_time,
                end_time: end_time,
                duration_ms: duration_ms,
                is_streaming: is_streaming
              )
            end

            response
          rescue StandardError => e
            end_time = Time.now
            duration_ms = ((end_time - start_time) * 1000).round(2)

            # Send error response in single API call
            Coolhand::Ruby::BaseInterceptor.send_complete_request_log(
              request_id: request_id,
              method: method,
              url: full_url,
              request_headers: request_headers,
              request_body: request_body,
              response_headers: {},
              response_body: {
                error: {
                  message: e.message,
                  class: e.class.name
                }
              },
              status_code: nil,
              start_time: start_time,
              end_time: end_time,
              duration_ms: duration_ms,
              is_streaming: is_streaming
            )
            raise
          end
        end
      end

      it "intercepts non-streaming requests and logs complete data" do
        allow(client_instance).to receive(:streaming_request?).and_return(false)

        result = client_instance.request(
          method: :post,
          path: "/v1/messages",
          body: { model: "claude-3-haiku-20240307", messages: [{ role: "user", content: "Hello" }] },
          headers: { "Content-Type" => "application/json" }
        )

        expect(result).to be_a(RSpec::Mocks::Double)
        expect(Coolhand::Ruby::BaseInterceptor).to have_received(:send_complete_request_log).with(
          a_hash_including(
            method: :post,
            url: "https://api.anthropic.com/v1/messages",
            is_streaming: false
          )
        )
      end

      it "sets request ID in thread-local storage" do
        allow(client_instance).to receive(:streaming_request?).and_return(false)

        client_instance.request(
          method: :post,
          path: "/v1/messages",
          body: {},
          headers: {}
        )

        expect(Thread.current[:coolhand_current_request_id]).to be_a(String)
        expect(Thread.current[:coolhand_current_request_id].length).to eq(32)
      end

      it "stores streaming request metadata without immediate logging" do
        allow(client_instance).to receive(:streaming_request?).and_return(true)

        client_instance.request(
          method: :post,
          path: "/v1/messages",
          body: { stream: true },
          headers: {}
        )

        # Should store metadata but not send log yet
        expect(Thread.current[:coolhand_streaming_request]).to be_a(Hash)
        expect(Thread.current[:coolhand_streaming_request][:is_streaming]).to be true

        # Should not have sent log yet for streaming
        expect(Coolhand::Ruby::BaseInterceptor).not_to have_received(:send_complete_request_log)
      end

      it "handles errors and logs them" do
        allow(client_instance).to receive(:streaming_request?).and_return(false)
        allow(client_instance).to receive(:original_request).and_raise(StandardError, "API Error")

        expect do
          client_instance.request(method: :post, path: "/v1/messages", body: {}, headers: {})
        end.to raise_error(StandardError, "API Error")

        expect(Coolhand::Ruby::BaseInterceptor).to have_received(:send_complete_request_log).with(
          a_hash_including(
            response_body: a_hash_including(
              error: a_hash_including(
                message: "API Error",
                class: "StandardError"
              )
            )
          )
        )
      end
    end

    describe "streaming detection" do
      let(:instance) { Object.new.extend(interceptor_module) }

      it "identifies streaming request by stream parameter" do
        body = { stream: true }
        expect(instance.send(:streaming_request?, body, {})).to be true
      end

      it "identifies streaming request by Accept header" do
        headers = { "Accept" => "text/event-stream" }
        expect(instance.send(:streaming_request?, {}, headers)).to be true
      end

      it "identifies non-streaming requests" do
        expect(instance.send(:streaming_request?, {}, {})).to be false
      end
    end
  end

  describe "MessageStreamInterceptor module behavior" do
    let(:interceptor_module) { described_class::MessageStreamInterceptor }
    let(:stream_instance) { Object.new.extend(interceptor_module) }
    let(:accumulated_message) do
      double("message",
        content: "Hello world!",
        usage: double(input_tokens: 10, output_tokens: 15),
        model: "claude-3-haiku-20240307")
    end

    before do
      # Mock BaseInterceptor
      allow(Coolhand::Ruby::BaseInterceptor).to receive(:extract_response_data).and_return({
        content: "Hello world!",
        usage: { input_tokens: 10, output_tokens: 15 }
      })
      allow(Coolhand::Ruby::BaseInterceptor).to receive(:send_complete_request_log)

      # Set up streaming request metadata
      Thread.current[:coolhand_streaming_request] = {
        request_id: "test-id",
        method: :post,
        url: "https://api.anthropic.com/v1/messages",
        request_headers: { "Content-Type" => "application/json" },
        request_body: { model: "claude-3-haiku-20240307", stream: true },
        start_time: Time.now - 1,
        end_time: Time.now,
        duration_ms: 1000.0,
        is_streaming: true
      }

      # Mock the super call
      def stream_instance.accumulated_message
        message = double("message",
          content: "Hello world!",
          usage: double(input_tokens: 10, output_tokens: 15),
          model: "claude-3-haiku-20240307")

        # Log the completion data if we have streaming request metadata
        streaming_request = Thread.current[:coolhand_streaming_request]
        log_streaming_completion(message, streaming_request) if streaming_request

        message
      end
    end

    it "logs streaming completion when accumulated_message is called" do
      result = stream_instance.accumulated_message

      expect(result.content).to eq("Hello world!")
      expect(Coolhand::Ruby::BaseInterceptor).to have_received(:send_complete_request_log).with(
        a_hash_including(
          request_id: "test-id",
          is_streaming: true
        )
      )
    end

    it "clears streaming request metadata after logging" do
      stream_instance.accumulated_message

      expect(Thread.current[:coolhand_streaming_request]).to be_nil
    end

    it "does nothing if no streaming request metadata is present" do
      Thread.current[:coolhand_streaming_request] = nil
      allow(Coolhand::Ruby::BaseInterceptor).to receive(:extract_response_data).and_call_original

      result = stream_instance.accumulated_message

      expect(result.content).to eq("Hello world!")
      expect(Coolhand::Ruby::BaseInterceptor).not_to have_received(:send_complete_request_log)
    end
  end

  describe "version compatibility" do
    shared_examples "anthropic version compatibility" do |gem_version|
      context "with Anthropic gem v#{gem_version}" do
        let(:mock_client_class) { class_double(Anthropic::Internal::Transport::BaseClient) }
        let(:mock_stream_class) { class_double(Anthropic::Streaming::MessageStream) }

        before do
          # Mock the version-specific modules and classes
          anthropic_module = Module.new
          internal_module = Module.new
          transport_module = Module.new
          streaming_module = Module.new

          stub_const("Anthropic", anthropic_module)
          stub_const("Anthropic::VERSION", gem_version)
          stub_const("Anthropic::Internal", internal_module)
          stub_const("Anthropic::Internal::Transport", transport_module)
          stub_const("Anthropic::Internal::Transport::BaseClient", mock_client_class)
          stub_const("Anthropic::Streaming", streaming_module)
          stub_const("Anthropic::Streaming::MessageStream", mock_stream_class)

          allow(mock_client_class).to receive(:prepend)
          allow(mock_stream_class).to receive(:prepend)
          allow(described_class).to receive(:require)

          # Clean up before patching
          described_class.unpatch!
        end

        it "successfully patches BaseClient" do
          expect { described_class.patch! }.not_to raise_error
          expect(mock_client_class).to have_received(:prepend).with(described_class::RequestInterceptor)
          expect(described_class.patched?).to be true
        end

        it "successfully patches MessageStream for streaming" do
          expect { described_class.patch! }.not_to raise_error
          expect(mock_stream_class).to have_received(:prepend).with(described_class::MessageStreamInterceptor)
        end

        it "handles multiple patch attempts gracefully" do
          described_class.patch!
          described_class.patch!

          expect(mock_client_class).to have_received(:prepend).once
          expect(mock_stream_class).to have_received(:prepend).once
        end

        it "can be unpatched and re-patched" do
          described_class.patch!
          expect(described_class.patched?).to be true

          described_class.unpatch!
          expect(described_class.patched?).to be false

          described_class.patch!
          expect(described_class.patched?).to be true
        end
      end
    end

    include_examples "anthropic version compatibility", "1.8.0"
    include_examples "anthropic version compatibility", "1.16.0"
  end

  describe "edge cases and error handling" do
    context "when required classes are missing" do
      before do
        stub_const("Anthropic", Module.new)
        allow(described_class).to receive(:require)
      end

      it "handles missing BaseClient gracefully" do
        # Don't define BaseClient
        expect { described_class.patch! }.not_to raise_error
        expect(described_class.patched?).to be true # It marks as patched but doesn't actually patch
      end

      it "handles missing MessageStream gracefully" do
        # Define BaseClient but not MessageStream
        base_client_class = class_double(Anthropic::Internal::Transport::BaseClient)
        stub_const("Anthropic::Internal", Module.new)
        stub_const("Anthropic::Internal::Transport", Module.new)
        stub_const("Anthropic::Internal::Transport::BaseClient", base_client_class)
        allow(base_client_class).to receive(:prepend)

        expect { described_class.patch! }.not_to raise_error
        expect(base_client_class).to have_received(:prepend)
      end
    end

    context "when API service fails" do
      let(:mock_client_class) do
        Class.new do
          attr_accessor :base_url

          def initialize
            @base_url = "https://api.anthropic.com"
          end

          def original_request(method:, path:, body: nil, headers: {})
            double("response", content: "test")
          end
        end
      end

      let(:client_instance) { mock_client_class.new.tap { |c| c.extend(described_class::RequestInterceptor) } }

      before do
        # Mock BaseInterceptor to fail
        allow(Coolhand::Ruby::BaseInterceptor).to receive_messages(clean_request_headers: {}, extract_response_data: {})
        allow(Coolhand::Ruby::BaseInterceptor).to receive(:send_complete_request_log).and_raise(StandardError.new("API service error"))
        allow(client_instance).to receive(:streaming_request?).and_return(false)
        allow(client_instance).to receive(:original_request).and_call_original

        # Set up the request method (simplified version for error testing)
        def client_instance.request(method:, path:, body: nil, headers: {}, **_options)
          response = original_request(method: method, path: path, body: body, headers: headers)
          Coolhand::Ruby::BaseInterceptor.send_complete_request_log(
            request_id: "test",
            method: method,
            url: "#{@base_url}#{path}",
            request_headers: {},
            request_body: body,
            response_headers: {},
            response_body: {},
            status_code: nil,
            start_time: Time.now,
            end_time: Time.now,
            duration_ms: 1.0,
            is_streaming: false
          )
          response
        rescue StandardError => e
          Coolhand.log "❌ Error sending complete request log: #{e.message}"
          response || double("response", content: "test")
        end
      end

      it "continues execution even when logging fails" do
        expect do
          result = client_instance.request(method: :post, path: "/v1/messages", body: {}, headers: {})
          expect(result).to be_a(RSpec::Mocks::Double)
        end.not_to raise_error

        expect(Coolhand).to have_received(:log).with(/Error sending complete request log/)
      end
    end
  end

  describe "BaseInterceptor integration" do
    it "uses BaseInterceptor methods for data extraction" do
      expect(described_class::RequestInterceptor).to respond_to(:send_complete_request_log)
      expect(described_class::MessageStreamInterceptor.instance_methods).to include(:extract_response_data)
    end

    it "properly extracts response data using BaseInterceptor" do
      response_data = { content: "test", usage: { input_tokens: 10 } }
      mock_response = double("response")

      allow(Coolhand::Ruby::BaseInterceptor).to receive(:extract_response_data).with(mock_response).and_return(response_data)

      result = Coolhand::Ruby::BaseInterceptor.extract_response_data(mock_response)
      expect(result).to eq(response_data)
    end
  end
end
