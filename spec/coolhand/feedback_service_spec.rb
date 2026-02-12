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
          id: 123,
          llm_request_log_id: 456,
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
        expect(result[:id]).to eq(123)
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
            expect(feedback_data["like"]).to be(false)
            expect(feedback_data["explanation"]).to eq("Poor response")
            expect(feedback_data["revised_output"]).to eq("Better response")
            expect(feedback_data["llm_provider_unique_id"]).to eq("provider-123")
            expect(feedback_data["original_output"]).to eq("Original")
            expect(feedback_data["client_unique_id"]).to eq("client-456")
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
          id: 789,
          llm_request_log_id: 12_345,
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

        expect(result[:id]).to eq(789)
        expect(result[:llm_request_log_id]).to eq(12_345)
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
  end
end
