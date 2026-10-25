# frozen_string_literal: true

require "spec_helper"
require "openai"
require "coolhand/open_ai/batch_result_processor"

RSpec.describe Coolhand::OpenAi::BatchResultProcessor do
  let(:logger) { instance_double("logger", info: nil, warn: nil, error: nil) }
  let(:client) { instance_double(OpenAI::Client) }
  let(:api_service) { instance_double(Coolhand::ApiService, send_llm_request_log: nil) }

  before do
    stub_const("Rails", Class.new)

    allow(Rails).to receive(:logger).and_return(logger)
    allow(OpenAI::Client).to receive(:new).and_return(client)
    allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
  end

  describe "#call" do
    context "when batch is in_progress" do
      let(:batch_info) { { "id" => "batch_abc121", "status" => "in_progress" } }

      it "logs that the batch is still processing and does not process results" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        expect(Rails.logger).to receive(:info).with(a_string_including("still processing"))
        described_class.new(event_data: { "id" => "batch_abc121" }).call
      end
    end

    context "when batch failed" do
      let(:batch_info) { { "id" => "batch_abc122", "status" => "failed", "errors" => ["boom"] } }

      it "logs the failure error" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        expect(Rails.logger).to receive(:error).with(a_string_including("failed").and(a_string_including("boom")))
        described_class.new(event_data: { "id" => "batch_abc122" }).call
      end
    end

    context "when batch completed" do
      let(:start_time) { 1_700_000_000 } # epoch seconds
      let(:end_time)   { start_time + 5 } # 5 seconds later => 5000 ms
      let(:batch_info) do
        {
          "id" => "batch_abc123",
          "status" => "completed",
          "input_file_id" => "file-abcIn123",
          "output_file_id" => "file-abcOut4",
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
          { "custom_id" => "c1",
            "response" => { "request_id" => "req-123", "body" => { "ok" => true }, "status_code" => 200 } }
        ].map(&:to_json).join("\n")
      end

      it "downloads files, matches by custom_id and sends request log with expected fields (JSONL string parsing)" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(input_items_jsonl)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(output_items_jsonl)

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

        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end

      it "handles when client already returns parsed arrays for files" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)

        parsed_input = [{ "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/1",
                          "body" => { "foo" => "bar" } }]
        parsed_output = [{ "custom_id" => "c1",
                           "response" => { "request_id" => "req-456", "body" => { "ok" => true },
                                           "status_code" => 200 } }]

        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(parsed_input)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(parsed_output)

        expect(api_service).to receive(:send_llm_request_log)
          .with(hash_including(raw_request: hash_including(id: "req-456")))

        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end

      it "pairs each response with its request via a custom_id index, keeping the first of duplicate ids" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        parsed_input = [
          { "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/first", "body" => { "n" => 1 } },
          { "custom_id" => "c2", "method" => "POST", "url" => "https://api.example/second", "body" => { "n" => 2 } },
          { "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/dupe", "body" => { "n" => 3 } }
        ]
        parsed_output = %w[c2 c1].map do |id|
          { "custom_id" => id, "response" => { "request_id" => "req-#{id}", "body" => {}, "status_code" => 200 } }
        end
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(parsed_input)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(parsed_output)

        expect(api_service).to receive(:send_llm_request_log)
          .with(hash_including(raw_request: hash_including(id: "req-c2", url: "https://api.example/second")))
          .ordered
        expect(api_service).to receive(:send_llm_request_log)
          .with(hash_including(raw_request: hash_including(id: "req-c1", url: "https://api.example/first")))
          .ordered

        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end

      it "processes the completed batch on the background log queue when async_logging is on" do
        Coolhand.configuration.async_logging = true
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(input_items_jsonl)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(output_items_jsonl)
        sending_thread = nil
        allow(api_service).to receive(:send_llm_request_log) { sending_thread = Thread.current }

        described_class.new(event_data: { "id" => "batch_abc123" }).call
        Coolhand.flush(timeout: 2)

        expect(sending_thread).not_to be_nil
        expect(sending_thread).not_to eq(Thread.current)
      end

      it "logs an error raised while processing in the background instead of letting it escape" do
        Coolhand.configuration.async_logging = true
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        processor = described_class.new(event_data: { "id" => "batch_abc123" })
        allow(processor).to receive(:download_batch_results).and_raise(StandardError, "kaboom")

        expect { processor.call }.not_to raise_error
        Coolhand.flush(timeout: 2)

        expect(logger).to have_received(:error)
          .with(a_string_including("Failed to process OpenAI batch").and(a_string_including("kaboom")))
      end

      it "skips a response item with no matching request custom_id and sends nothing for it" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(input_items_jsonl)

        unmatched_output = [
          { "custom_id" => "no-such-request",
            "response" => { "request_id" => "req-999", "body" => {}, "status_code" => 200 } }
        ].map(&:to_json).join("\n")
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(unmatched_output)

        expect(api_service).not_to receive(:send_llm_request_log)

        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end

      it "redacts data_sources credentials from the request body before forwarding" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)

        secret_body = { "messages" => [], "data_sources" => [{ "parameters" => { "key" => "s3cret" } }] }
        secret_input = [{ "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/1",
                          "body" => secret_body }]
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(secret_input)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(output_items_jsonl)

        expect(api_service).to receive(:send_llm_request_log) do |request_data|
          sent_body = request_data[:raw_request][:request_body]
          expect(sent_body["data_sources"].first["parameters"]["key"]).to eq("[REDACTED]")
          expect(sent_body.to_json).not_to include("s3cret")
        end

        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end

      it "pairs a response with the first request item when a custom_id is duplicated" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)

        duplicated_input = [
          { "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/first", "body" => {} },
          { "custom_id" => "c1", "method" => "POST", "url" => "https://api.example/second", "body" => {} }
        ]
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcIn123").and_return(duplicated_input)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-abcOut4").and_return(output_items_jsonl)

        expect(api_service).to receive(:send_llm_request_log)
          .with(hash_including(raw_request: hash_including(url: "https://api.example/first")))

        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end
    end

    context "when the webhook event carries an invalid batch id" do
      ["../../v1/models", "batch_x/y", "batch_x?y=1", "file-abc123", "batch_", "", nil, 42].each do |bad_id|
        it "does not call the OpenAI API for id #{bad_id.inspect}" do
          expect(client).not_to receive(:batches)
          expect(logger).to receive(:error).with(a_string_including("invalid batch ID"))

          expect { described_class.new(event_data: { "id" => bad_id }).call }.not_to raise_error
        end
      end

      [nil, "batch_abc123", ["batch_abc123"]].each do |bad_event|
        it "does not call the OpenAI API for event data #{bad_event.inspect}" do
          expect(client).not_to receive(:batches)

          expect { described_class.new(event_data: bad_event).call }.not_to raise_error
        end
      end

      it "accepts Azure-style UUID batch ids" do
        uuid_id = "batch_0b9f6a52-1c3d-4e7a-9a58-3f1d2c4b5a6e"
        expect(client).to receive_message_chain(:batches, :retrieve).with(id: uuid_id)
          .and_return({ "id" => uuid_id, "status" => "in_progress" })

        described_class.new(event_data: { "id" => uuid_id }).call
      end
    end

    context "when a completed batch has problems with its file ids or timestamps" do
      let(:batch_info) do
        {
          "id" => "batch_abc123",
          "status" => "completed",
          "input_file_id" => "file-abcIn123",
          "output_file_id" => "file-abcOut4",
          "in_progress_at" => 1_700_000_000,
          "completed_at" => 1_700_000_005
        }
      end

      before do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
      end

      def process_batch
        described_class.new(event_data: { "id" => "batch_abc123" }).call
      end

      [
        ["input_file_id", "../v1/models"],
        ["input_file_id", "file-abc/def"],
        ["output_file_id", "file-abc?x=1"],
        ["output_file_id", "batch_abc123"],
        ["output_file_id", 123]
      ].each do |field, bad_id|
        it "downloads nothing when #{field} is #{bad_id.inspect}" do
          batch_info[field] = bad_id
          expect(client).not_to receive(:files)
          expect(api_service).not_to receive(:send_llm_request_log)
          expect(logger).to receive(:error).with(a_string_including("invalid"))

          process_batch
        end
      end

      it "accepts file ids with underscore or UUID tails" do
        batch_info["input_file_id"] = "file_abc-123"
        batch_info["output_file_id"] = "file-0b9f6a52-1c3d-4e7a-9a58-3f1d2c4b5a6e"
        expect(logger).not_to receive(:error)
        allow(client).to receive_message_chain(:files, :content).and_return([])

        process_batch
      end

      [
        { "in_progress_at" => nil },
        { "completed_at" => nil },
        { "in_progress_at" => 0 },
        { "completed_at" => "soon" },
        { "in_progress_at" => nil, "completed_at" => nil }
      ].each do |overrides|
        it "skips the batch and logs an error for #{overrides}" do
          batch_info.merge!(overrides)
          expect(client).not_to receive(:files)
          expect(api_service).not_to receive(:send_llm_request_log)
          expect(logger).to receive(:error).with(a_string_including("in_progress_at/completed_at"))

          process_batch
        end
      end

      it "clamps duration_ms to 0 when completed_at precedes in_progress_at" do
        batch_info["completed_at"] = batch_info["in_progress_at"] - 10
        allow(client).to receive_message_chain(:files, :content).and_return(
          [{ "custom_id" => "c1", "method" => "POST", "url" => "/v1/chat/completions", "body" => {} }],
          [{ "custom_id" => "c1", "response" => { "request_id" => "r1", "body" => {}, "status_code" => 200 } }]
        )
        expect(logger).to receive(:warn).with(a_string_including("clamping"))
        expect(api_service).to receive(:send_llm_request_log)
          .with(hash_including(raw_request: hash_including(duration_ms: 0)))

        process_batch
      end
    end

    context "when sending request logs for a completed batch" do
      let(:batch_info) do
        {
          "id" => "batch_abc123",
          "status" => "completed",
          "input_file_id" => "file-abcIn123",
          "output_file_id" => "file-abcOut4",
          "in_progress_at" => 1_700_000_000,
          "completed_at" => 1_700_000_005
        }
      end
      let(:request_url) { "/v1/chat/completions" }
      let(:request_body) { { "model" => "gpt-4o-mini", "messages" => [] } }
      let(:response_body) { { "id" => "chatcmpl-1", "model" => "gpt-4o-mini-2024-07-18" } }

      before do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).and_return(
          [{ "custom_id" => "c1", "method" => "POST", "url" => request_url, "body" => request_body }],
          [{ "custom_id" => "c1",
             "response" => { "request_id" => "r1", "body" => response_body, "status_code" => 200 } }]
        )
      end

      def sent_request
        sent = nil
        allow(api_service).to receive(:send_llm_request_log) { |data| sent = data[:raw_request] }
        described_class.new(event_data: { "id" => "batch_abc123" }).call
        sent
      end

      it "prefixes a relative request URL with the OpenAI API host" do
        expect(sent_request[:url]).to eq("https://api.openai.com/v1/chat/completions")
      end

      it "sends source_api openai and the model from the request body" do
        expect(sent_request).to include(source_api: "openai", model: "gpt-4o-mini")
      end

      context "when the request body has no model" do
        let(:request_body) { { "messages" => [] } }

        it "falls back to the model in the response body" do
          expect(sent_request[:model]).to eq("gpt-4o-mini-2024-07-18")
        end
      end

      context "when the request body model is not a string" do
        let(:request_body) { { "model" => { "x" => 1 } } }

        it "ignores it and falls back to the response body model" do
          expect(sent_request[:model]).to eq("gpt-4o-mini-2024-07-18")
        end
      end

      context "when neither body has a model" do
        let(:request_body) { nil }
        let(:response_body) { { "id" => "chatcmpl-1" } }

        it "omits the model" do
          expect(sent_request).not_to have_key(:model)
        end
      end

      context "when the request URL is already absolute" do
        let(:request_url) { "https://api.openai.com/v1/embeddings" }

        it "leaves the URL unchanged" do
          expect(sent_request[:url]).to eq("https://api.openai.com/v1/embeddings")
        end
      end
    end

    context "when batch status is unrecognized" do
      let(:batch_info) { { "id" => "batch_abc124", "status" => "some_future_status" } }

      it "logs a warning and does not raise" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        expect(Rails.logger).to receive(:warn).with(a_string_including("Unknown batch status"))
        expect { described_class.new(event_data: { "id" => "batch_abc124" }).call }.not_to raise_error
      end
    end

    context "when downloading a batch result file fails outright (e.g. network error)" do
      let(:batch_info) do
        {
          "id" => "batch_abc126",
          "status" => "completed",
          "input_file_id" => "file-in-down",
          "output_file_id" => "file-out-down",
          "in_progress_at" => 1_700_000_000,
          "completed_at" => 1_700_000_005
        }
      end

      it "logs a download error and treats the file as having no items, without raising" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-in-down")
          .and_raise(StandardError, "connection reset")
        allow(client).to receive_message_chain(:files, :content).with(id: "file-out-down")
          .and_raise(StandardError, "connection reset")

        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to download OpenAI batch results"))
          .at_least(:once)
        expect(api_service).not_to receive(:send_llm_request_log)

        expect { described_class.new(event_data: { "id" => "batch_abc126" }).call }.not_to raise_error
      end
    end

    context "when a batch result file is malformed JSONL" do
      let(:batch_info) do
        {
          "id" => "batch_abc125",
          "status" => "completed",
          "input_file_id" => "file-in-bad",
          "output_file_id" => "file-out-bad",
          "in_progress_at" => 1_700_000_000,
          "completed_at" => 1_700_000_005
        }
      end

      it "logs a parse error and treats the file as having no items, without raising" do
        allow(client).to receive_message_chain(:batches, :retrieve).and_return(batch_info)
        allow(client).to receive_message_chain(:files, :content).with(id: "file-in-bad").and_return("not json{{{")
        allow(client).to receive_message_chain(:files, :content).with(id: "file-out-bad").and_return("not json{{{")

        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to parse OpenAI batch results"))
          .at_least(:once)
        expect(api_service).not_to receive(:send_llm_request_log)

        expect { described_class.new(event_data: { "id" => "batch_abc125" }).call }.not_to raise_error
      end
    end
  end
end
