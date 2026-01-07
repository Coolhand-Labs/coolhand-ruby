# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Vertex::BatchResultProcessor do
  let(:logger) { instance_double("logger", info: nil, warn: nil, error: nil) }

  before do
    stub_const("Rails", Class.new)
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe "#call" do
    context "when batch is pending/running/queued" do
      let(:batch_info) { { "state" => "JOB_STATE_RUNNING", "displayName" => "batch_x" } }

      it "does not process completed batch items" do
        processor = described_class.new(batch_info: batch_info)
        expect(processor).not_to receive(:process_completed_batch)
        processor.call([{ "request" => {}, "response" => {} }])
      end
    end

    context "when batch succeeded" do
      let(:batch_info) do
        {
          "name" => "projects/1/locations/us/batchPredictionJobs/1",
          "displayName" => "evals_batch_53",
          "startTime" => "2026-01-04T20:16:56.310023Z",
          "endTime" => "2026-01-04T20:21:38.785842Z",
          "state" => "JOB_STATE_SUCCEEDED"
        }
      end

      let(:batch_item) do
        {
          "request" => { "input" => "foo" },
          "response" => { "output" => "bar" }
        }
      end

      it "sends a request log to the API with expected payload shape" do
        fixed_id = "fixed_request_id"
        allow(SecureRandom).to receive(:hex).and_return(fixed_id)

        api_service = instance_double(Coolhand::ApiService)
        expect(Coolhand::ApiService).to receive(:new).and_return(api_service)

        # compute expected duration in ms same way the service does
        start_time = Time.iso8601(batch_info["startTime"])
        end_time   = Time.iso8601(batch_info["endTime"])
        expected_duration_ms = ((end_time - start_time) * 1000).to_i

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(
              id: fixed_id,
              timestamp: start_time,
              method: "post",
              url: batch_info["name"],
              request_body: batch_item["request"],
              response_body: batch_item["response"],
              status_code: 200,
              duration_ms: expected_duration_ms,
              completed_at: end_time,
              is_streaming: false
            )
          )
        )

        processor = described_class.new(batch_info: batch_info)
        processor.call([batch_item])
      end
    end

    context "when batch failed" do
      let(:batch_info) do
        {
          "displayName" => "evals_batch_bad",
          "state" => "JOB_STATE_FAILED",
          "error" => { "message" => "something went wrong" }
        }
      end

      it "logs the failure error" do
        expect(Rails.logger).to receive(:error)
          .with(a_string_including("failed").and(a_string_including("something went wrong")))
        processor = described_class.new(batch_info: batch_info)
        processor.call
      end
    end
  end
end
