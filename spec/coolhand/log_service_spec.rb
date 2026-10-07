# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::LogService do
  let(:endpoint) { "https://coolhandlabs.com/api/v2/llm_request_logs" }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-private-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }
  let(:log_row) do
    {
      id: "l1a2b3c4d5e6",
      collector: "ruby-1.0",
      source_api: "openai",
      source_application: nil,
      metadata: {},
      source_api_result: "success",
      model: "gpt-4o",
      template_id: "kp9npvc8qq2q",
      template_name: "Support summariser",
      input_tokens: 100,
      output_tokens: 20,
      latency_ms: 800,
      created_at: "2026-09-01T12:00:00Z",
      updated_at: "2026-09-01T12:00:00Z",
      ingest_evidence: {},
      cost: 0.0042
    }
  end
  let(:cost_breakdown) do
    {
      total_cost: 0.0042, input_cost: 0.0025, output_cost: 0.0017,
      cached_input_cost: 0.0, cache_creation_input_cost: 0.0, reasoning_output_cost: 0.0
    }
  end

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  def stub_list(body:, status: 200, headers: { "X-Page" => "1", "X-Per-Page" => "25" })
    stub_request(:get, /llm_request_logs/).to_return(
      status: status,
      body: JSON.generate(body),
      headers: headers.merge("Content-Type" => "application/json")
    )
  end

  describe "Coolhand.log_service" do
    it "returns a LogService, distinct from the write-side logger_service" do
      expect(Coolhand.log_service).to be_a(described_class)
      expect(Coolhand.log_service).not_to be_a(Coolhand::LoggerService)
    end
  end

  describe "#search_logs" do
    context "with the request it builds" do
      before { stub_list(body: []) }

      it "sends the private API key and asks for JSON" do
        service.search_logs

        expect(WebMock).to have_requested(:get, endpoint)
          .with(headers: { "X-API-Key" => "test-private-key", "Accept" => "application/json" })
      end

      it "maps every keyword onto its wire parameter" do
        service.search_logs(
          template_id: "t1", workload_id: "w1", system_prompt_contains: "sys", user_prompt_contains: "usr",
          model: "gpt-4o", source_api: "openai", source_api_result: "success", source_application: "app",
          project_path: "/p", unmatched_only: true, days_back: 7, since: "2026-09-01", until: "2026-10-01",
          min_cost: 0.5, order: "cost_desc", include_prompts: true, include_total: true,
          sort: "created_at desc", page: 2, per: 50
        )

        expect(WebMock).to have_requested(:get, endpoint).with(query: {
          "template_id" => "t1", "workload_id" => "w1", "system_prompt_contains" => "sys",
          "user_prompt_contains" => "usr", "model" => "gpt-4o", "source_api" => "openai",
          "source_api_result" => "success", "source_application" => "app", "project_path" => "/p",
          "unmatched_only" => "true", "days_back" => "7", "since" => "2026-09-01", "until" => "2026-10-01",
          "min_cost" => "0.5", "order" => "cost_desc", "include_prompts" => "true", "include_total" => "true",
          "q[s]" => "created_at desc", "page" => "2", "per" => "50"
        })
      end

      it "sends min_cost=0 and include_total=false rather than dropping them" do
        service.search_logs(min_cost: 0, include_total: false, unmatched_only: false)

        expect(WebMock).to have_requested(:get, endpoint)
          .with(query: { "min_cost" => "0", "include_total" => "false", "unmatched_only" => "false" })
      end

      it "passes an unknown order through, leaving the 422 to the server" do
        service.search_logs(order: "bogus")

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "order" => "bogus" })
      end

      it "serialises Time windows as UTC ISO8601" do
        service.search_logs(since: Time.utc(2026, 9, 1), until: DateTime.new(2026, 10, 1, 0, 0, 0, "+00:00"))

        expect(WebMock).to have_requested(:get, endpoint)
          .with(query: { "since" => "2026-09-01T00:00:00Z", "until" => "2026-10-01T00:00:00Z" })
      end

      it "keeps fractional seconds on Time and DateTime windows" do
        service.search_logs(
          since: Time.utc(2026, 9, 1, 0, 0, 0, 123_456),
          until: DateTime.new(2026, 10, 1, 0, 0, Rational(1, 2))
        )

        expect(WebMock).to have_requested(:get, endpoint)
          .with(query: { "since" => "2026-09-01T00:00:00.123456Z", "until" => "2026-10-01T00:00:00.500000Z" })
      end

      it "raises ArgumentError before any request for an invalid window value" do
        expect { service.search_logs(until: 12) }.to raise_error(ArgumentError, /until/)
        expect(WebMock).not_to have_requested(:get, /llm_request_logs/)
      end

      it "rejects a client_id instead of sending one" do
        expect { service.search_logs(client_id: "x") }.to raise_error(ArgumentError, /client_id/)
      end
    end

    context "with a successful response" do
      it "returns the bare array as Symbol-keyed Hashes, with cost as a Float" do
        stub_list(body: [log_row, log_row.merge(id: "l2", cost: nil)])

        logs = service.search_logs.logs

        expect(logs.map { |l| l[:id] }).to eq(%w[l1a2b3c4d5e6 l2])
        expect(logs.first[:cost]).to eq(0.0042)
        expect(logs.last[:cost]).to be_nil
      end

      it "reads pagination from the headers when include_total is set" do
        stub_list(body: [log_row], headers: {
          "X-Page" => "2", "X-Per-Page" => "10", "X-Total-Count" => "31", "X-Total-Pages" => "4"
        })

        expect(service.search_logs(include_total: true, page: 2, per: 10).pagination).to have_attributes(
          current_page: 2, per_page: 10, total_count: 31, total_pages: 4, has_next_page: true, has_prev_page: true
        )
      end

      it "reports a next page from the page being full when the totals headers are absent" do
        stub_list(body: Array.new(10) { log_row }, headers: { "X-Page" => "1", "X-Per-Page" => "10" })

        expect(service.search_logs(per: 10).pagination).to have_attributes(
          current_page: 1, per_page: 10, has_next_page: true, has_prev_page: false
        )
      end

      it "reports no next page when a short page comes back without totals" do
        stub_list(body: [log_row], headers: { "X-Page" => "1", "X-Per-Page" => "25" })

        expect(service.search_logs.pagination.has_next_page).to be(false)
      end
    end

    describe "error handling" do
      it "carries 401, 422 and 504 on the HttpError" do
        { 401 => { error: "x" }, 422 => { errors: { min_cost: ["must be >= 0"] } },
          504 => { errors: { system: ["timeout"] } } }.each do |status, body|
          stub_list(body: body, status: status)

          expect { service.search_logs(min_cost: -1) }.to raise_error(an_object_having_attributes(status: status))
        end
      end

      it "raises when a 200 body is not an array" do
        stub_request(:get, /llm_request_logs/).to_return(status: 200, body: "{}")

        expect { service.search_logs }.to raise_error(Coolhand::Error, /not a JSON array/)
      end

      it "raises without making a request when no API key is configured" do
        allow(config).to receive(:api_key).and_return("")

        expect { service.search_logs }.to raise_error(Coolhand::Error, /API key is required/)
        expect(WebMock).not_to have_requested(:get, /llm_request_logs/)
      end
    end
  end

  describe "#get_log" do
    let(:detail) { log_row.merge(cost_breakdown: cost_breakdown, system_prompt: nil, user_prompt: "hi", output: "yo") }

    it "fetches the log by hashid and returns Symbol-keyed cost and cost_breakdown" do
      stub_request(:get, "#{endpoint}/l1a2b3c4d5e6").to_return(status: 200, body: JSON.generate(detail))

      result = service.get_log("l1a2b3c4d5e6")

      expect(result[:cost]).to eq(0.0042)
      expect(result[:cost_breakdown]).to include(total_cost: 0.0042, reasoning_output_cost: 0.0)
    end

    it "maps the show options onto their wire parameters" do
      stub_request(:get, %r{llm_request_logs/l1}).to_return(status: 200, body: "{}")

      service.get_log("l1", section: "end", max_chars: 100, search_query: "refund", include_thinking: false)

      expect(WebMock).to have_requested(:get, "#{endpoint}/l1").with(query: {
        "section" => "end", "max_chars" => "100", "search_query" => "refund", "include_thinking" => "false"
      })
    end

    it "keeps a null cost and cost_breakdown as nil" do
      stub_request(:get, %r{llm_request_logs/l1})
        .to_return(status: 200, body: JSON.generate(log_row.merge(cost: nil, cost_breakdown: nil)))

      result = service.get_log("l1")

      expect(result).to include(cost: nil, cost_breakdown: nil)
    end

    it "escapes the id so it cannot retarget the request" do
      stub_request(:get, /llm_request_logs/).to_return(status: 200, body: "{}")

      service.get_log("a/b?c")

      expect(WebMock).to have_requested(:get, "#{endpoint}/a%2Fb%3Fc")
    end

    it "rejects a blank, non-String or dot-segment id without a request" do
      [nil, "", "  ", ".", "..", 12].each do |bad|
        expect { service.get_log(bad) }.to raise_error(Coolhand::Error, /get_log: id/)
      end
      expect(WebMock).not_to have_requested(:get, /llm_request_logs/)
    end

    it "raises HttpError with status 404 for an unknown log" do
      stub_request(:get, %r{llm_request_logs/nope}).to_return(status: 404, body: '{"errors":{"id":["not found"]}}')

      expect { service.get_log("nope") }.to raise_error(an_object_having_attributes(status: 404))
    end
  end
end
