# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::WorkloadService do
  let(:endpoint) { "https://coolhandlabs.com/api/v2/workloads" }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-private-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }
  let(:metrics) do
    {
      days_back: nil,
      since: "2026-09-01T00:00:00Z",
      until: "2026-10-01T00:00:00Z",
      request_count: 10,
      failure_count: 2,
      error_rate: 0.2,
      error_rate_change: nil,
      avg_cost_per_request: 0.0125,
      total_cost: 0.1,
      priced_request_count: 8,
      long_context_request_count: 1,
      total_input_tokens: 1200,
      total_output_tokens: 340,
      avg_input_tokens: 150,
      avg_output_tokens: 42,
      avg_latency_ms: 812.5,
      correctness_score: nil,
      sentiment_score: nil,
      revision_score: nil,
      first_request_at: "2026-08-01T00:00:00Z",
      last_request_at: "2026-09-30T00:00:00Z"
    }
  end
  let(:workload) do
    {
      id: "w7x2mn4qk1zz",
      name: "Support",
      description: nil,
      archived: false,
      system: false,
      merged: false,
      template_count: 3,
      draft_template_count: 1,
      log_count: 40,
      last_activity: "2026-09-30T00:00:00Z",
      metrics: metrics
    }
  end
  let(:pagination_headers) do
    { "X-Page" => "1", "X-Per-Page" => "25", "X-Total-Count" => "1", "X-Total-Pages" => "1" }
  end

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  def stub_list(body:, status: 200, headers: pagination_headers)
    stub_request(:get, /workloads/).to_return(
      status: status,
      body: JSON.generate(body),
      headers: headers.merge("Content-Type" => "application/json")
    )
  end

  describe "Coolhand.workload_service" do
    it "returns a WorkloadService" do
      expect(Coolhand.workload_service).to be_a(described_class)
    end
  end

  describe "#initialize" do
    it "hangs off the workloads collection on the configured base_url" do
      expect(service.api_endpoint).to eq(endpoint)
    end
  end

  describe "#search_workloads" do
    context "with the request it builds" do
      before { stub_list(body: []) }

      it "sends the private API key and asks for JSON" do
        service.search_workloads

        expect(WebMock).to have_requested(:get, endpoint)
          .with(headers: { "X-API-Key" => "test-private-key", "Accept" => "application/json" })
      end

      it "maps every keyword onto its wire parameter" do
        service.search_workloads(
          search: "supp", include_archived: true, include_system: false, include_templates: true,
          include_metrics: true, days_back: 7, since: "2026-09-01", until: "2026-10-01", page: 2, per: 50
        )

        expect(WebMock).to have_requested(:get, endpoint).with(query: {
          "search" => "supp",
          "include_archived" => "true",
          "include_system" => "false",
          "include_templates" => "true",
          "include_metrics" => "true",
          "days_back" => "7",
          "since" => "2026-09-01",
          "until" => "2026-10-01",
          "page" => "2",
          "per" => "50"
        })
      end

      it "sends no query string when nothing is given" do
        service.search_workloads

        expect(WebMock).to have_requested(:get, endpoint)
      end

      it "sends false and 0 rather than dropping them" do
        service.search_workloads(include_metrics: false, days_back: 0)

        expect(WebMock).to have_requested(:get, endpoint)
          .with(query: { "include_metrics" => "false", "days_back" => "0" })
      end

      it "sends per and never per_page" do
        service.search_workloads(per: 10)

        expect(WebMock).to(have_requested(:get, /workloads/).with do |req|
          expect(req.uri.query_values).to eq("per" => "10")
        end)
      end

      it "rejects a client_id instead of sending one" do
        expect { service.search_workloads(client_id: "x") }.to raise_error(ArgumentError, /client_id/)
      end
    end

    describe "since and until" do
      before { stub_list(body: []) }

      it "serialises a Time as UTC ISO8601" do
        service.search_workloads(since: Time.new(2026, 9, 1, 12, 0, 0, "-05:00"), until: Time.utc(2026, 10, 1))

        expect(WebMock).to have_requested(:get, endpoint)
          .with(query: { "since" => "2026-09-01T17:00:00Z", "until" => "2026-10-01T00:00:00Z" })
      end

      it "does not mutate the caller's Time" do
        time = Time.new(2026, 9, 1, 12, 0, 0, "-05:00")

        service.search_workloads(since: time)

        expect(time.utc_offset).to eq(-5 * 3600)
      end

      it "serialises a DateTime as UTC ISO8601" do
        service.search_workloads(since: DateTime.new(2026, 9, 1, 12, 0, 0, "+02:00"))

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "since" => "2026-09-01T10:00:00Z" })
      end

      it "serialises a Date as a date alone, which the server reads as midnight UTC" do
        service.search_workloads(since: Date.new(2026, 9, 1))

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "since" => "2026-09-01" })
      end

      it "encodes a + offset in a String as %2B so the server does not read it as a space" do
        service.search_workloads(since: "2026-09-01T12:00:00+02:00")

        expect(WebMock).to have_requested(:get, /workloads\?since=2026-09-01T12:00:00%2B02:00\z/)
      end

      it "passes a malformed String through for the server to reject" do
        service.search_workloads(since: "bad")

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "since" => "bad" })
      end

      it "raises ArgumentError before any request for anything else" do
        expect { service.search_workloads(since: 1_700_000_000) }.to raise_error(ArgumentError, /since/)
        expect { service.search_workloads(until: :now) }.to raise_error(ArgumentError, /until/)
        expect(WebMock).not_to have_requested(:get, /workloads/)
      end
    end

    context "with a successful response" do
      before { stub_list(body: [workload]) }

      it "returns the rows as Hashes with Symbol keys" do
        expect(service.search_workloads.workloads).to eq([workload])
      end

      it "keeps the id a hashid string and metrics nulls as nil" do
        row = service.search_workloads(include_metrics: true).workloads.first

        expect(row[:id]).to eq("w7x2mn4qk1zz")
        expect(row[:metrics]).to include(days_back: nil, failure_count: 2, total_input_tokens: 1200,
          priced_request_count: 8, long_context_request_count: 1, error_rate_change: nil)
      end

      it "reads pagination from the response headers" do
        stub_list(body: [workload],
          headers: { "X-Page" => "3", "X-Per-Page" => "10", "X-Total-Count" => "97", "X-Total-Pages" => "10" })

        expect(service.search_workloads(page: 3, per: 10).pagination).to eq(
          Coolhand::Pagination.new(
            current_page: 3, per_page: 10, total_count: 97, total_pages: 10,
            has_next_page: true, has_prev_page: true
          )
        )
      end

      it "returns a frozen WorkloadSearchResult" do
        expect(service.search_workloads).to be_frozen.and be_a(Coolhand::WorkloadSearchResult)
      end
    end

    describe "error handling" do
      it "carries 401 on a HttpError" do
        stub_list(body: { error: "Invalid API key" }, status: 401)

        expect { service.search_workloads }.to raise_error(an_object_having_attributes(status: 401))
      end

      it "carries the 422 status and the server's errors body" do
        stub_list(body: { errors: { since: ["is not a valid ISO8601 timestamp"] } }, status: 422)

        expect { service.search_workloads(include_metrics: true, since: "bad") }
          .to raise_error(Coolhand::HttpError, /422/) { |e| expect(e.body).to include("since") }
      end

      it "surfaces 504 as itself" do
        stub_list(body: { errors: { system: ["Query timed out"] } }, status: 504)

        expect { service.search_workloads }.to raise_error(an_object_having_attributes(status: 504))
      end

      it "raises when a 200 body is not an array" do
        stub_request(:get, /workloads/).to_return(status: 200, body: "{}")

        expect { service.search_workloads }.to raise_error(Coolhand::Error, /not a JSON array/)
      end

      it "raises without making a request when no API key is configured" do
        allow(config).to receive(:api_key).and_return(nil)

        expect { service.search_workloads }.to raise_error(Coolhand::Error, /API key is required/)
        expect(WebMock).not_to have_requested(:get, /workloads/)
      end
    end
  end

  describe "#upsert" do
    let(:key_url) { "#{endpoint}/by_key/Parser%23call/squish%3AL2" }
    let(:json_headers) { { "Content-Type" => "application/json" } }

    it "PUTs the compacted body to the by_key route with the private key and returns the workload" do
      stub = stub_request(:put, key_url)
        .with(headers: { "X-API-Key" => "test-private-key", "Content-Type" => "application/json" },
          body: { name: "Parser", description: "d", reporter: "squishling" }.to_json)
        .to_return(status: 201, body: workload.to_json, headers: json_headers)

      result = service.upsert(key: "Parser#call/squish:L2", name: "Parser", description: "d", reporter: "squishling")

      expect(result).to eq(workload)
      expect(stub).to have_been_requested
    end

    it "sends an empty body object when only the key is given" do
      stub = stub_request(:put, "#{endpoint}/by_key/Parser").with(body: "{}")
        .to_return(status: 200, body: workload.to_json)

      service.upsert(key: "Parser")
      expect(stub).to have_been_requested
    end

    it "raises HttpError carrying the status on 401 and 422" do
      stub_request(:put, "#{endpoint}/by_key/k").to_return({ status: 401, body: '{"error":"no"}' },
        { status: 422, body: { errors: { external_key: ["is invalid"] } }.to_json })

      expect { service.upsert(key: "k") }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(401) }
      expect { service.upsert(key: "k") }.to raise_error(Coolhand::HttpError, /is invalid/) { |e|
        expect(e.status).to eq(422)
      }
    end

    it "raises Error before any request for a blank or dot-segment key" do
      ["", "  ", nil, "..", "a/../b", ".", "/a", "a/", "a//b"].each do |key|
        expect { service.upsert(key: key) }.to raise_error(Coolhand::Error, /key must be a non-empty string/)
      end
      expect(WebMock).not_to have_requested(:put, /.*/)
    end

    it "wraps transport failures in Coolhand::Error" do
      stub_request(:put, "#{endpoint}/by_key/k").to_timeout

      expect { service.upsert(key: "k") }.to raise_error(Coolhand::Error, /Workload request failed/)
    end
  end
end
