# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::FeedbackService do
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-api-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  describe "#initialize" do
    it "configures with production endpoint" do
      expect(service.api_endpoint).to eq("https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
    end

    it "uses configuration.base_url for its endpoint" do
      custom_config = instance_double(Coolhand::Configuration,
        api_key: "test-api-key",
        base_url: "https://self-hosted.example.com/api",
        silent: true,
        environment: "production",
        debug_mode: false)
      allow(Coolhand).to receive(:configuration).and_return(custom_config)
      expect(described_class.new.api_endpoint).to eq(
        "https://self-hosted.example.com/api/v2/llm_request_log_feedbacks"
      )
    end
  end

  describe "#create_feedback" do
    let(:feedback) do
      {
        llm_request_log_id: 456,
        like: true,
        explanation: "Great response!"
      }
    end

    context "when API call is successful" do
      let(:mock_response) do
        {
          id: "xyz789abc123",
          llm_request_log_id: "abc123def456",
          like: true,
          explanation: "Great response!",
          created_at: "2023-01-01T00:00:00Z",
          updated_at: "2023-01-01T00:00:00Z"
        }
      end

      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with(
            headers: {
              "Content-Type" => "application/json",
              "X-API-Key" => "test-api-key"
            }
          )
          .to_return(
            status: 200,
            body: JSON.generate(mock_response),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "successfully creates feedback" do
        result = service.create_feedback(feedback)

        expect(result).not_to be_nil
        expect(result[:id]).to eq("xyz789abc123")
        expect(result[:like]).to be(true)
        expect(result[:explanation]).to eq("Great response!")
      end

      it "structures payload correctly" do
        comprehensive_feedback = {
          llm_request_log_id: 456,
          like: false,
          explanation: "Poor response",
          revised_output: "Better response",
          llm_provider_unique_id: "provider-123",
          original_output: "Original",
          client_unique_id: "client-456"
        }

        service.create_feedback(comprehensive_feedback)

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            body = JSON.parse(req.body)
            feedback_data = body["llm_request_log_feedback"]

            expect(feedback_data["llm_request_log_id"]).to eq(456)
            expect(feedback_data).not_to have_key("like")
            expect(feedback_data["sentiment"]).to eq("dislike")
            expect(feedback_data["explanation"]).to eq("Poor response")
            expect(feedback_data["revised_output"]).to eq("Better response")
            expect(feedback_data["llm_provider_unique_id"]).to eq("provider-123")
            expect(feedback_data["original_output"]).to eq("Original")
            expect(feedback_data["client_unique_id"]).to eq("client-456")
          end)
      end

      it "sends sentiment field in payload" do
        service.create_feedback({ llm_request_log_id: 456, sentiment: "dislike" })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data["sentiment"]).to eq("dislike")
          end)
      end

      it "sends workload_hashid field in payload" do
        service.create_feedback({ llm_request_log_id: 456, workload_hashid: "abc123" })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data["workload_hashid"]).to eq("abc123")
          end)
      end

      it "sends creator_type field in payload" do
        service.create_feedback({ llm_request_log_id: 456, creator_type: "agent" })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data["creator_type"]).to eq("agent")
          end)
      end

      it "converts like: true to sentiment: 'like'" do
        service.create_feedback({ llm_request_log_id: 456, like: true })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data["sentiment"]).to eq("like")
          end)
      end

      it "converts like: false to sentiment: 'dislike'" do
        service.create_feedback({ llm_request_log_id: 456, like: false })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data["sentiment"]).to eq("dislike")
          end)
      end

      it "strips like from the payload after conversion" do
        service.create_feedback({ llm_request_log_id: 456, like: true })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data).not_to have_key("like")
          end)
      end

      it "does not convert like when sentiment is already set, and strips like from payload" do
        service.create_feedback({ llm_request_log_id: 456, like: true, sentiment: "neutral" })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data["sentiment"]).to eq("neutral")
            expect(feedback_data).not_to have_key("like")
          end)
      end

      it "does not add sentiment when like is omitted" do
        service.create_feedback({ llm_request_log_id: 456, explanation: "Good" })

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            feedback_data = JSON.parse(req.body)["llm_request_log_feedback"]
            expect(feedback_data).not_to have_key("sentiment")
          end)
      end

      it "includes collector field with manual method" do
        service.create_feedback(feedback)

        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            body = JSON.parse(req.body)
            feedback_data = body["llm_request_log_feedback"]

            # Check that collector field is present and has manual method
            expect(feedback_data).to have_key("collector")
            expect(feedback_data["collector"]).to eq("coolhand-ruby-#{Coolhand::VERSION}-manual")
          end)
      end
    end

    context "when API call fails" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .to_return(status: 400, body: "Bad Request")
      end

      it "handles failed API response gracefully" do
        result = service.create_feedback(feedback)
        expect(result).to be_nil
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .to_raise(StandardError.new("Network error"))
      end

      it "handles network errors gracefully" do
        result = service.create_feedback(feedback)
        expect(result).to be_nil
      end
    end

    context "with logging behavior" do
      context "when in silent mode" do
        it "does not output logs" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { service.create_feedback(feedback) }.not_to output(/CREATING FEEDBACK/).to_stdout
        end
      end

      context "when not in silent mode" do
        let(:verbose_config) do
          instance_double(Coolhand::Configuration,
            api_key: "test-api-key",
            base_url: "https://coolhandlabs.com/api",
            silent: false,
            environment: "production",
            debug_mode: false)
        end

        let(:verbose_service) do
          allow(Coolhand).to receive(:configuration).and_return(verbose_config)
          described_class.new
        end

        it "outputs verbose logs" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback(feedback) }
            .to output(/📝 CREATING FEEDBACK/).to_stdout
        end

        it "logs the provider unique id when feedback is keyed by llm_provider_unique_id" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback({ llm_provider_unique_id: "chatcmpl-abc", like: true }) }
            .to output(/CREATING FEEDBACK for Provider Unique ID: chatcmpl-abc/).to_stdout
        end

        it "prefers llm_request_log_id over llm_provider_unique_id when both are given" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect do
            verbose_service.create_feedback({ llm_request_log_id: 456, llm_provider_unique_id: "chatcmpl-abc" })
          end.to output(/for LLM Request Log ID: 456/).to_stdout
        end

        it "logs a bare header when no identifier is given" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback({ sentiment: "like" }) }
            .to output(/CREATING FEEDBACK\n/).to_stdout
        end

        it "logs sentiment when present" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback({ llm_request_log_id: 456, sentiment: "like" }) }
            .to output(/Sentiment: like/).to_stdout
        end

        it "logs like: true as Sentiment: like after auto-conversion" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback({ llm_request_log_id: 456, like: true }) }
            .to output(/Sentiment: like/).to_stdout
        end

        it "logs workload_hashid when present" do
          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback({ llm_request_log_id: 456, workload_hashid: "abc123" }) }
            .to output(/Workload: abc123/).to_stdout
        end

        it "truncates long explanations in logs" do
          long_feedback = {
            llm_request_log_id: 456,
            like: true,
            explanation: "A" * 150
          }

          stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
            .to_return(status: 200, body: JSON.generate({ id: 123 }))

          expect { verbose_service.create_feedback(long_feedback) }
            .to output(/A{100}\.\.\./).to_stdout
        end
      end
    end

    context "with usage examples" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .to_return(
            status: 200,
            body: JSON.generate(mock_response),
            headers: { "Content-Type" => "application/json" }
          )
      end

      let(:mock_response) do
        {
          id: "mno345pqr678",
          llm_request_log_id: "def456ghi789",
          like: true,
          explanation: "This response was helpful and accurate!",
          created_at: "2023-01-01T00:00:00Z",
          updated_at: "2023-01-01T00:00:00Z"
        }
      end

      it "creates feedback with basic fields" do
        feedback = {
          llm_request_log_id: 12_345,
          like: true,
          explanation: "This response was helpful and accurate!"
        }

        result = service.create_feedback(feedback)

        expect(result[:id]).to eq("mno345pqr678")
        expect(result[:llm_request_log_id]).to eq("def456ghi789")
        expect(result[:like]).to be(true)
      end

      it "creates negative feedback with revision" do
        feedback = {
          llm_request_log_id: 12_346,
          like: false,
          explanation: "The response could be more detailed",
          revised_output: "Here is a more detailed version..."
        }

        result = service.create_feedback(feedback)
        expect(result).not_to be_nil
      end

      it "creates comprehensive feedback with all fields" do
        feedback = {
          llm_request_log_id: 12_347,
          like: true,
          explanation: "Perfect response",
          revised_output: nil,
          llm_provider_unique_id: "gpt-4-response-123",
          original_output: "The original AI response...",
          client_unique_id: "user-session-456"
        }

        result = service.create_feedback(feedback)

        expect(result).not_to be_nil
        expect(WebMock).to(have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .with do |req|
            body = JSON.parse(req.body)
            feedback_data = body["llm_request_log_feedback"]
            expect(feedback_data["llm_provider_unique_id"]).to eq("gpt-4-response-123")
            expect(feedback_data["client_unique_id"]).to eq("user-session-456")
          end)
      end
    end

    context "when the feedback names a client_unique_id" do
      let(:feedback) { { client_unique_id: "abc.1", sentiment: "like" } }

      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .to_return(status: 200, body: JSON.generate(id: "fb1"), headers: { "Content-Type" => "application/json" })
      end

      it "waits for that log before sending" do
        allow(Coolhand::LogQueue).to receive(:await_delivery).and_return(:delivered)

        expect(service.create_feedback(feedback)).to eq({ id: "fb1" })
        expect(Coolhand::LogQueue).to have_received(:await_delivery)
          .with("abc.1", timeout: described_class::LOG_WAIT_TIMEOUT)
      end

      it "sends right away when the log is not queued here" do
        allow(Coolhand::LogQueue).to receive(:await_delivery).and_return(:none)

        expect(service.create_feedback(feedback)).to eq({ id: "fb1" })
      end

      it "does not send, and returns nil, when the log failed to send" do
        allow(Coolhand::LogQueue).to receive(:await_delivery).and_return(:failed)
        allow(service).to receive(:log)

        expect(service.create_feedback(feedback)).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
        expect(service).to have_received(:log).with(a_string_including("failed to send"))
      end

      it "sends anyway, with a warning, when the log is still sending after the wait" do
        allow(Coolhand::LogQueue).to receive(:await_delivery).and_return(:timeout)
        allow(service).to receive(:log)

        expect(service.create_feedback(feedback)).to eq({ id: "fb1" })
        expect(service).to have_received(:log).with(a_string_including("before its log finished"))
      end

      it "holds the feedback POST until the queued log send completes" do
        allow(config).to receive(:async_logging).and_return(true)
        release = Queue.new
        Coolhand::LogQueue.submit(client_unique_id: "abc.1") { release.pop }

        sender = Thread.new { service.create_feedback(feedback) }
        sleep 0.01 until sender.status == "sleep"
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")

        release << { id: "log" }
        expect(sender.value).to eq({ id: "fb1" })
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
      end

      it "does not wait for a log queued by a different process, and still sends" do
        allow(config).to receive(:async_logging).and_return(true)
        release = Queue.new
        Coolhand::LogQueue.submit(client_unique_id: "abc.1") { release.pop }
        allow(Process).to receive(:pid).and_return(Process.pid + 1) # as in a forked child

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(service.create_feedback(feedback)).to eq({ id: "fb1" })
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        release << true
      end

      it "does not wait when feedback has no client_unique_id" do
        allow(Coolhand::LogQueue).to receive(:await_delivery)

        service.create_feedback(llm_request_log_id: "abc", sentiment: "like")

        expect(Coolhand::LogQueue).not_to have_received(:await_delivery)
      end
    end
  end

  describe "#create_feedback with raise_on_error: true" do
    let(:url) { "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks" }
    let(:feedback) { { client_unique_id: "order-42.1", sentiment: "like" } }

    it "raises instead of returning nil when the log for the client_unique_id failed to send" do
      allow(Coolhand::LogQueue).to receive(:await_delivery).and_return(:failed)

      expect { service.create_feedback(feedback, raise_on_error: true) }
        .to raise_error(Coolhand::Error, /log for client_unique_id "order-42\.1" failed to send/)
      expect(WebMock).not_to have_requested(:post, url)
    end

    it "returns the parsed response on success" do
      stub_request(:post, url).to_return(status: 201, body: JSON.generate({ id: "fb1" }))

      expect(service.create_feedback(feedback, raise_on_error: true)).to eq({ id: "fb1" })
    end

    it "raises HttpError carrying the status and body for a non-2xx response" do
      stub_request(:post, url).to_return(status: 422, body: "no matching log")

      expect { service.create_feedback(feedback, raise_on_error: true) }
        .to raise_error(Coolhand::HttpError) { |error|
          expect(error.status).to eq(422)
          expect(error.body).to eq("no matching log")
          expect(error.message).to include("422", "no matching log")
        }
    end

    it "raises Coolhand::Error for a network failure" do
      stub_request(:post, url).to_raise(StandardError.new("boom"))

      expect { service.create_feedback(feedback, raise_on_error: true) }
        .to raise_error(Coolhand::Error, /boom/)
    end

    it "treats a 2xx with a blank or non-JSON body as delivered, not as a failure to retry" do
      stub_request(:post, url).to_return({ status: 204, body: "" }, { status: 200, body: "not json" })

      expect(service.create_feedback(feedback, raise_on_error: true)).to eq({})
      expect(service.create_feedback(feedback, raise_on_error: true)).to eq({})
    end

    it "does not retry, so a failed feedback is never sent twice" do
      stub_request(:post, url).to_return(status: 503, body: "")

      expect { service.create_feedback(feedback, raise_on_error: true) }.to raise_error(Coolhand::HttpError)
      expect(WebMock).to have_requested(:post, url).once
    end

    it "raises when the API key is missing, and sends nothing" do
      allow(config).to receive(:api_key).and_return(nil)

      expect { service.create_feedback(feedback, raise_on_error: true) }
        .to raise_error(Coolhand::Error, /API key is required/)
      expect(WebMock).not_to have_requested(:post, url)
    end

    it "still returns nil without raising by default" do
      stub_request(:post, url).to_return(status: 500, body: "")
      allow(config).to receive(:api_key).and_return(nil)

      expect(service.create_feedback(feedback)).to be_nil
    end

    it "accepts the feedback fields as bare keywords alongside raise_on_error" do
      stub_request(:post, url).to_return(status: 200, body: JSON.generate({ id: "fb1" }))

      expect(service.create_feedback(client_unique_id: "order-42.1", sentiment: "like", raise_on_error: true))
        .to eq({ id: "fb1" })
      expect(WebMock).to(have_requested(:post, url).with do |req|
        JSON.parse(req.body)["llm_request_log_feedback"]["client_unique_id"] == "order-42.1"
      end)
    end

    it "rejects a misspelled option next to a feedback Hash instead of sending it as a field" do
      expect { service.create_feedback(feedback, raise_on_eror: true) }
        .to raise_error(ArgumentError, /raise_on_eror/)
      expect(WebMock).not_to have_requested(:post, url)
    end

    it "returns nil in debug mode even when raising is on" do
      allow(config).to receive(:debug_mode).and_return(true)

      expect(service.create_feedback(feedback, raise_on_error: true)).to be_nil
    end
  end

  describe "#create_feedback success message" do
    let(:url) { "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks" }

    before do
      allow(config).to receive(:silent).and_return(false)
      stub_request(:post, url).to_return(status: 200, body: JSON.generate({ id: "fb1" }))
    end

    {
      llm_request_log_id: ["abc123", "LLM Request Log ID"],
      llm_provider_unique_id: ["chatcmpl-9", "Provider Unique ID"],
      client_unique_id: ["order-42.1", "Client Unique ID"]
    }.each do |field, (value, label)|
      it "names the #{field} it matched by, never N/A" do
        expect { service.create_feedback(field => value, sentiment: "like") }
          .to output(/Successfully created feedback \(#{label}: #{Regexp.escape(value)}\)/).to_stdout
      end
    end

    it "prints no identifier when the feedback has none" do
      expect { service.create_feedback(sentiment: "like") }
        .to output(/Successfully created feedback$/).to_stdout
    end

    it "announces a client_unique_id feedback by that id" do
      expect { service.create_feedback(client_unique_id: "order-42.1", sentiment: "like") }
        .to output(/CREATING FEEDBACK for Client Unique ID: order-42.1/).to_stdout
    end
  end
end
