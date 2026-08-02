# frozen_string_literal: true

require "spec_helper"
require "logger"
require "coolhand/vertex/batch_result_processor"

RSpec.describe Coolhand::Vertex::BatchResultProcessor do
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  before do
    stub_const("Rails", Class.new)
    allow(Rails).to receive(:logger).and_return(logger)
    Coolhand.configuration.silent = true
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
              timestamp: start_time.iso8601,
              method: "post",
              url: "https://aiplatform.googleapis.com/v1/#{batch_info['name']}",
              source_api: "vertex",
              headers: {},
              request_body: batch_item["request"],
              response_headers: {},
              response_body: batch_item["response"],
              status_code: 200,
              duration_ms: expected_duration_ms,
              completed_at: end_time.iso8601,
              is_streaming: false
            )
          )
        )

        processor = described_class.new(batch_info: batch_info)
        processor.call([batch_item])
      end

      it "omits the model field when neither an explicit model nor batch_info's model is available" do
        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(raw_request: hash_excluding(:model))
        )

        processor = described_class.new(batch_info: batch_info)
        processor.call([batch_item])
      end

      it "sends the explicitly provided model when given" do
        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(source_api: "vertex", model: "gemini-2.0-flash")
          )
        )

        processor = described_class.new(batch_info: batch_info, model: "gemini-2.0-flash")
        processor.call([batch_item])
      end

      it "sends an explicitly provided model containing a slash unchanged when it isn't a resource path" do
        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(model: "meta-llama/Llama-3")
          )
        )

        processor = described_class.new(batch_info: batch_info, model: "meta-llama/Llama-3")
        processor.call([batch_item])
      end

      it "falls back to batch_info's model when no explicit model is given, normalizing a resource path " \
         "to its bare model id" do
        batch_info_with_model = batch_info.merge("model" => "publishers/google/models/gemini-2.0-flash")

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(model: "gemini-2.0-flash")
          )
        )

        processor = described_class.new(batch_info: batch_info_with_model)
        processor.call([batch_item])
      end

      it "normalizes a project-scoped model resource path with a version suffix" do
        batch_info_with_model = batch_info.merge(
          "model" => "projects/1/locations/us-central1/models/gemini-2.0-flash@1"
        )

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(model: "gemini-2.0-flash@1")
          )
        )

        processor = described_class.new(batch_info: batch_info_with_model)
        processor.call([batch_item])
      end

      it "falls back to batch_info's model when the explicit model is a blank string" do
        batch_info_with_model = batch_info.merge("model" => "publishers/google/models/gemini-2.0-flash")

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(model: "gemini-2.0-flash")
          )
        )

        processor = described_class.new(batch_info: batch_info_with_model, model: "  ")
        processor.call([batch_item])
      end

      it "omits the model field when batch_info's model is a blank string and no explicit model is given" do
        batch_info_with_blank_model = batch_info.merge("model" => "   ")

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(raw_request: hash_excluding(:model))
        )

        processor = described_class.new(batch_info: batch_info_with_blank_model)
        processor.call([batch_item])
      end

      it "prefers the explicit model over batch_info's model when both are present" do
        batch_info_with_model = batch_info.merge("model" => "publishers/google/models/gemini-2.0-flash")

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(
            raw_request: hash_including(model: "gemini-2.0-flash")
          )
        )

        processor = described_class.new(batch_info: batch_info_with_model, model: "gemini-2.0-flash")
        processor.call([batch_item])
      end

      it "skips sending a request log when the batch job has no resource name" do
        batch_info_without_name = batch_info.merge("name" => nil)

        expect(Coolhand::ApiService).not_to receive(:new)
        expect(Rails.logger).to receive(:error).with(a_string_including("missing or invalid job resource name"))

        processor = described_class.new(batch_info: batch_info_without_name)
        processor.call([batch_item])
      end

      it "skips sending a request log when the resource name doesn't match the expected Vertex shape" do
        batch_info_with_bad_name = batch_info.merge("name" => "not-a-valid-resource-name?evil=1")

        expect(Coolhand::ApiService).not_to receive(:new)
        expect(Rails.logger).to receive(:error).with(a_string_including("missing or invalid job resource name"))

        processor = described_class.new(batch_info: batch_info_with_bad_name)
        processor.call([batch_item])
      end

      it "strips a leading slash from the resource name so the URL isn't double-slashed" do
        batch_info_with_leading_slash = batch_info.merge("name" => "/#{batch_info['name']}")

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(raw_request: hash_including(url: "https://aiplatform.googleapis.com/v1/#{batch_info['name']}"))
        )

        processor = described_class.new(batch_info: batch_info_with_leading_slash)
        processor.call([batch_item])
      end

      it "skips sending a request log when startTime/endTime are missing or invalid" do
        batch_info_with_bad_time = batch_info.merge("startTime" => "not-a-timestamp")

        expect(Coolhand::ApiService).not_to receive(:new)
        expect(Rails.logger).to receive(:error).with(a_string_including("missing or invalid startTime/endTime"))

        processor = described_class.new(batch_info: batch_info_with_bad_time)
        processor.call([batch_item])
      end

      it "skips sending a request log when startTime is nil" do
        batch_info_with_nil_time = batch_info.merge("startTime" => nil)

        expect(Coolhand::ApiService).not_to receive(:new)
        expect(Rails.logger).to receive(:error).with(a_string_including("missing or invalid startTime/endTime"))

        processor = described_class.new(batch_info: batch_info_with_nil_time)
        processor.call([batch_item])
      end

      it "clamps duration_ms to 0 and still sends the log when endTime is before startTime" do
        batch_info_with_reversed_times = batch_info.merge(
          "startTime" => batch_info["endTime"], "endTime" => batch_info["startTime"]
        )

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
        expect(api_service).to receive(:send_llm_request_log).with(
          hash_including(raw_request: hash_including(duration_ms: 0))
        )
        expect(Rails.logger).to receive(:warn).with(a_string_including("endTime before its startTime"))

        processor = described_class.new(batch_info: batch_info_with_reversed_times)
        processor.call([batch_item])
      end

      it "computes shared batch data once and sends one log per item for a multi-item batch" do
        other_item = { "request" => { "input" => "baz" }, "response" => { "output" => "qux" } }

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)

        sent = []
        allow(api_service).to receive(:send_llm_request_log) { |data| sent << data[:raw_request] }

        processor = described_class.new(batch_info: batch_info)
        processor.call([batch_item, other_item])

        expect(sent.size).to eq(2)
        expect(sent.map { |r| r[:url] }.uniq).to eq(["https://aiplatform.googleapis.com/v1/#{batch_info['name']}"])
        expect(sent.map { |r| r[:duration_ms] }.uniq.size).to eq(1)
        expect(sent.map { |r| r[:id] }.uniq.size).to eq(2)
        expect(sent.map { |r| r[:request_body] }).to eq([batch_item["request"], other_item["request"]])
      end

      it "still sends the remaining items when one item's data is malformed" do
        malformed_item = nil

        api_service = instance_double(Coolhand::ApiService)
        allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
        sent = []
        allow(api_service).to receive(:send_llm_request_log) { |data| sent << data[:raw_request] }
        expect(Rails.logger).to receive(:error).with(a_string_including("malformed result item"))
        expect(Rails.logger).to receive(:warn).with(a_string_including("Dispatched 1/2 result(s)"))

        processor = described_class.new(batch_info: batch_info)
        expect { processor.call([malformed_item, batch_item]) }.not_to raise_error

        expect(sent.size).to eq(1)
      end

      it "rejects a Hash item with neither request nor response keys instead of sending an empty-bodied log" do
        keyless_item = { "other" => "stuff" }

        expect(Coolhand::ApiService).not_to receive(:new)
        expect(Rails.logger).to receive(:error).with(a_string_including("malformed result item"))

        processor = described_class.new(batch_info: batch_info)
        processor.call([keyless_item])
      end

      it "logs success with a zero count and sends nothing for an empty batch" do
        info_messages = []
        allow(Rails.logger).to receive(:info) { |msg| info_messages << msg }
        expect(Coolhand::ApiService).not_to receive(:new)

        processor = described_class.new(batch_info: batch_info)
        processor.call([])

        expect(info_messages).to include(a_string_including("Dispatched 0 result(s)"))
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

      context "when error is missing or not a Hash" do
        let(:batch_info) { { "displayName" => "evals_batch_bad", "state" => "JOB_STATE_FAILED", "error" => nil } }

        it "still logs the batch-failure message (not the generic outer-rescue message from a NoMethodError " \
           "on nil['message'])" do
          expect(Rails.logger).to receive(:error)
            .with(a_string_including("Vertex batch for evals_batch_bad failed"))
          processor = described_class.new(batch_info: batch_info)
          expect { processor.call }.not_to raise_error
        end
      end
    end

    context "when batch state is unrecognized" do
      let(:batch_info) { { "displayName" => "batch_y", "state" => "JOB_STATE_SOME_FUTURE_STATE" } }

      it "logs a warning and does not raise" do
        expect(Rails.logger).to receive(:warn).with(a_string_including("Unknown batch status"))
        processor = described_class.new(batch_info: batch_info)
        expect { processor.call }.not_to raise_error
      end
    end
  end

  describe "loading this file in isolation" do
    it "defines Coolhand::Vertex::BatchResultProcessor via $LOAD_PATH alone, without spec_helper having " \
       "already loaded the rest of the gem first" do
      lib_path = File.expand_path("../../../lib", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(#{lib_path.inspect})
        require "coolhand/vertex/batch_result_processor"
        raise "BatchResultProcessor not defined" unless defined?(Coolhand::Vertex::BatchResultProcessor)
        puts "ok"
      RUBY

      # Strip bundler env so this isn't just re-requiring an already-loaded
      # coolhand via inherited RUBYOPT/BUNDLE_GEMFILE from `bundle exec
      # rspec`. NOTE: this still catches missing internal require_relative
      # statements, but NOT an undeclared external gem dependency — the
      # subprocess still shares this shell's GEM_HOME/GEM_PATH, so any gem
      # bundler installed for this project (declared or not) is still
      # resolvable. Catching an undeclared dependency needs a genuinely
      # empty GEM_HOME, which isn't set up here.
      output = `env -u RUBYOPT -u RUBYLIB -u BUNDLE_GEMFILE #{RbConfig.ruby.shellescape} -e #{script.shellescape} 2>&1`

      expect(output).to match(/^ok$/)
    end
  end
end
