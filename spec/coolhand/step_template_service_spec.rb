# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::StepTemplateService do
  let(:endpoint) { "https://coolhandlabs.com/api/v2/step_templates" }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-private-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }
  let(:row) do
    {
      id: 14,
      name: "/review",
      step_type: "prompt_step",
      status: "published",
      user_turn_pattern: nil,
      created_at: "2026-08-01T12:00:00Z",
      updated_at: "2026-08-02T12:00:00Z",
      sessions_count: 3,
      occurrences_count: 5,
      last_seen_at: nil
    }
  end
  let(:cohort) do
    {
      runs: 2, avg_turns_after: 1.5, avg_tool_calls: 4.0, avg_requests: 6.0, token_runs: 0,
      tokens_available: false, median_tokens: nil, p90_tokens: nil, tokens_per_tool_call: nil
    }
  end
  let(:metrics) do
    {
      total_runs: 2,
      tool_stats: nil,
      turn_stats: { avg: 2.0, median: 2.0, high: 3, single_turn_pct: nil },
      efficiency: { interactive: cohort, automated: nil, all: cohort, unavailable_runs: 1 },
      notes: ["Token figures are unavailable."]
    }
  end
  let(:pagination_headers) do
    { "X-Page" => "1", "X-Per-Page" => "25", "X-Total-Count" => "1", "X-Total-Pages" => "1" }
  end

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  def stub_list(body:, status: 200, headers: pagination_headers)
    stub_request(:get, /step_templates/).to_return(
      status: status,
      body: JSON.generate(body),
      headers: headers.merge("Content-Type" => "application/json")
    )
  end

  describe "#initialize" do
    it "hangs off the step templates collection on the configured base_url" do
      expect(service.api_endpoint).to eq(endpoint)
    end

    it "is reachable from Coolhand.step_template_service" do
      expect(Coolhand.step_template_service).to be_a(described_class)
    end
  end

  describe "#list_step_templates" do
    context "with the request it builds" do
      before { stub_list(body: []) }

      it "sends the private API key and asks for JSON" do
        service.list_step_templates

        expect(WebMock).to have_requested(:get, endpoint)
          .with(headers: { "X-API-Key" => "test-private-key", "Accept" => "application/json" })
      end

      it "sends no query string when no filters are given" do
        service.list_step_templates

        expect(WebMock).to have_requested(:get, endpoint).with(query: {})
      end

      it "maps every keyword onto its wire parameter" do
        service.list_step_templates(search: "rev", step_type: "tool_step", include_metrics: true, page: 2, per: 10)

        expect(WebMock).to have_requested(:get, endpoint).with(query: {
          "search" => "rev", "step_type" => "tool_step", "include_metrics" => "true", "page" => "2", "per" => "10"
        })
      end

      it "sends include_metrics=false rather than dropping an explicit false" do
        service.list_step_templates(include_metrics: false)

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "include_metrics" => "false" })
      end

      it "never sends per_page" do
        service.list_step_templates(per: 10)

        expect(WebMock).to(have_requested(:get, /step_templates/).with do |req|
          expect(req.uri.query_values).not_to have_key("per_page")
        end)
      end

      it "passes an unrecognised step_type straight through, leaving the 422 to the server" do
        service.list_step_templates(step_type: "bogus")

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "step_type" => "bogus" })
      end

      it "rejects a client_id instead of sending one" do
        expect { service.list_step_templates(client_id: "x") }.to raise_error(ArgumentError, /client_id/)
        expect(WebMock).not_to have_requested(:get, /step_templates/)
      end
    end

    context "with a successful response" do
      it "returns the rows as Symbol-keyed Hashes under #step_templates" do
        stub_list(body: [row])

        expect(service.list_step_templates.step_templates).to eq([row])
      end

      it "keeps the integer id and the nullable fields" do
        stub_list(body: [row])

        expect(service.list_step_templates.step_templates.first)
          .to include(id: 14, user_turn_pattern: nil, last_seen_at: nil)
      end

      it "omits metrics unless requested and keeps nested nulls when present" do
        stub_list(body: [row.merge(metrics: metrics)])

        found = service.list_step_templates(include_metrics: true).step_templates.first[:metrics]

        expect(found).to include(tool_stats: nil, notes: ["Token figures are unavailable."])
        expect(found[:efficiency]).to include(automated: nil, unavailable_runs: 1)
        expect(found[:efficiency][:all]).to include(tokens_available: false, median_tokens: nil)
      end
    end

    describe "pagination" do
      it "is read from the response headers" do
        stub_list(
          body: [row],
          headers: { "X-Page" => "3", "X-Per-Page" => "10", "X-Total-Count" => "97", "X-Total-Pages" => "10" }
        )

        expect(service.list_step_templates(page: 3, per: 10).pagination).to eq(
          Coolhand::Pagination.new(
            current_page: 3, per_page: 10, total_count: 97, total_pages: 10,
            has_next_page: true, has_prev_page: true
          )
        )
      end

      it "reports the per-page size the server applied, not the one requested" do
        stub_list(body: [row], headers: pagination_headers.merge("X-Per-Page" => "25"))

        expect(service.list_step_templates(include_metrics: true, per: 100).pagination.per_page).to eq(25)
      end
    end

    describe "error handling" do
      it "carries 401 on the error" do
        stub_list(body: { error: "Invalid API key" }, status: 401)

        expect { service.list_step_templates }.to raise_error(an_object_having_attributes(status: 401))
      end

      it "carries 422 for a bad step_type" do
        stub_list(body: { errors: { step_type: ["is invalid"] } }, status: 422)

        expect { service.list_step_templates(step_type: "bogus") }
          .to raise_error(Coolhand::HttpError, /Step template request failed \(422\)/) { |e| expect(e.status).to eq(422) }
      end

      it "surfaces 504 as itself" do
        stub_list(body: { errors: { system: ["Query timed out"] } }, status: 504)

        expect { service.list_step_templates }.to raise_error(an_object_having_attributes(status: 504))
      end

      it "raises Coolhand::Error for a body that is not an array" do
        stub_list(body: { not: "an array" })

        expect { service.list_step_templates }.to raise_error(Coolhand::Error, /not a JSON array/)
      end

      it "raises when no API key is configured, before any request" do
        allow(config).to receive(:api_key).and_return(nil)

        expect { service.list_step_templates }.to raise_error(Coolhand::Error, /API key is required/)
        expect(WebMock).not_to have_requested(:get, /step_templates/)
      end
    end
  end

  describe "#get_step_template" do
    it "fetches by integer id and returns a Symbol-keyed Hash" do
      stub_request(:get, "#{endpoint}/14").to_return(status: 200, body: JSON.generate(row.merge(metrics: metrics)))

      result = service.get_step_template(14)

      expect(result).to include(id: 14, name: "/review")
      expect(result[:metrics][:turn_stats]).to include(single_turn_pct: nil, high: 3)
      expect(WebMock).to have_requested(:get, "#{endpoint}/14").with(query: {})
    end

    it "sends include_metrics=false explicitly when the caller asks for it" do
      stub_request(:get, %r{step_templates/14}).to_return(status: 200, body: JSON.generate(row))

      service.get_step_template(14, include_metrics: false)

      expect(WebMock).to have_requested(:get, "#{endpoint}/14").with(query: { "include_metrics" => "false" })
    end

    it "rejects anything but a positive Integer with ArgumentError and no request" do
      ["14", nil, 0, -3, 1.5, true, []].each do |bad|
        expect { service.get_step_template(bad) }.to raise_error(ArgumentError, /get_step_template: id/)
      end
      expect(WebMock).not_to have_requested(:get, /step_templates/)
    end

    it "carries 404 for an unknown, draft or foreign step template" do
      stub_request(:get, %r{step_templates/99}).to_return(status: 404, body: '{"errors":{"id":["not found"]}}')

      expect { service.get_step_template(99) }.to raise_error(an_object_having_attributes(status: 404))
    end

    it "carries 401 and 504" do
      stub_request(:get, %r{step_templates/14}).to_return({ status: 401, body: "{}" }, { status: 504, body: "{}" })

      expect { service.get_step_template(14) }.to raise_error(an_object_having_attributes(status: 401))
      expect { service.get_step_template(14) }.to raise_error(an_object_having_attributes(status: 504))
    end
  end
end
