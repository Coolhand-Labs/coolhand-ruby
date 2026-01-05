require "spec_helper"

RSpec.describe Coolhand::OpenAi::BatchResultProcessor do
  let(:logger) { double("logger", info: nil, warn: nil, error: nil) }
  let(:client) { double("openai_client") }
  let(:api_service) { double("ApiService", send_llm_request_log: nil) }

  before do
    stub_const("Rails", Class.new)

    allow(Rails).to receive(:logger).and_return(logger)
    allow(OpenAI::Client).to receive(:new).and_return(client)
    allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
  end

  describe "#call" do
    context "when batch is in_progress" do
      let(:batch_info) { { "id" => "batch-1", "status" => "in_progress" } }

      it "logs that the batch is still processing and does not process results" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        expect(Rails.logger).to receive(:info).with(a_string_including("still processing"))
        described_class.new(event_data: { "id" => "batch-1" }).call
      end
    end

    context "when batch failed" do
      let(:batch_info) { { "id" => "batch-2", "status" => "failed", "errors" => ["boom"] } }

      it "logs the failure error" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        expect(Rails.logger).to receive(:error).with(a_string_including("failed").and(a_string_including("boom")))
        described_class.new(event_data: { "id" => "batch-2" }).call
      end
    end

    context "when batch completed" do
      let(:start_time) { 1_700_000_000 } # epoch seconds
      let(:end_time)   { start_time + 5 } # 5 seconds later => 5000 ms
      let(:batch_info) do
        {
          "id" => "batch-3",
          "status" => "completed",
          "input_file_id" => "file-in-1",
          "output_file_id" => "file-out-1",
          "in_progress_at" => start_time,
          "completed_at" => end_time
        }
      end

      let(:input_items_jsonl) do
        [
          { "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/1", "body" => { "foo" => "bar" } },
          { "custom_id" => "c2", "method" => "GET", "url" => "https://api.example/2", "body" => nil }
        ].map(&:to_json).join("\n")
      end

      let(:output_items_jsonl) do
        [
          { "custom_id" => "c1", "response" => { "request_id" => "req-123", "body" => { "ok" => true }, "status_code" => 200 } }
        ].map(&:to_json).join("\n")
      end

      it "downloads files, matches by custom_id and sends request log with expected fields (JSONL string parsing)" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-in-1").and_return(input_items_jsonl)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-out-1").and_return(output_items_jsonl)

        expected_duration_ms = ((end_time - start_time) * 1000).to_i
        expected_completed_at = Time.at(end_time).iso8601

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(
              id: "req-123",
              method: "post",
              url: "https://api.example/1",
              request_body: { "foo" => "bar" },
              response_body: { "ok" => true },
              status_code: 200,
              duration_ms: expected_duration_ms,
              completed_at: expected_completed_at,
              is_streaming: false
            )
          )
        )

        described_class.new(event_data: { "id" => "batch-3" }).call
      end

      it "handles when client already returns parsed arrays for files" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)

        parsed_input = [{ "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/1", "body" => { "foo" => "bar" } }]
        parsed_output = [{ "custom_id" => "c1", "response" => { "request_id" => "req-456", "body" => { "ok" => true }, "status_code" => 200 } }]

        allow(client).to receive_message_chain(:files, :content).with(id: "file-in-1").and_return(parsed_input)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-out-1").and_return(parsed_output)

        expect(api_service).to receive(:send_llm_request_log).with(hash_including(raw_request: hash_including(id: "req-456")))

        described_class.new(event_data: { "id" => "batch-3" }).call
      end
    end
  end
end

