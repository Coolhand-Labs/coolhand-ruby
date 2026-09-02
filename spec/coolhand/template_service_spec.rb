# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::TemplateService do
  let(:endpoint) { "https://coolhandlabs.com/api/v2/llm_request_templates" }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-private-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }

  # Every field the API definition declares on the list response, so the specs assert against the
  # documented shape rather than a convenient subset of it.
  let(:summary) do
    {
      id: "kp9npvc8qq2q",
      name: "Support summariser",
      status: "published",
      version: "3",
      group: "user_prompt_with_system_prompt",
      workload_id: "w7x2mn4qk1zz",
      workload_name: "Support",
      system_template: false,
      deprecated_at: nil,
      log_count: 42,
      created_at: "2026-08-01T12:00:00Z",
      updated_at: "2026-08-02T12:00:00Z"
    }
  end
  # show adds the two prompt patterns the list omits, and nothing else.
  let(:detail) do
    summary.merge(
      user_prompt_pattern: "\\ASummarise: (?<body>.+)\\z",
      system_prompt_pattern: nil
    )
  end
  let(:pagination_headers) do
    { "X-Page" => "1", "X-Per-Page" => "25", "X-Total-Count" => "1", "X-Total-Pages" => "1" }
  end

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  def stub_list(body:, status: 200, headers: pagination_headers)
    stub_request(:get, /llm_request_templates/).to_return(
      status: status,
      body: JSON.generate(body),
      headers: headers.merge("Content-Type" => "application/json")
    )
  end

  describe "#initialize" do
    it "hangs off the templates collection on the configured base_url" do
      expect(service.api_endpoint).to eq(endpoint)
    end

    it "follows a self-hosted base_url" do
      allow(config).to receive(:base_url).and_return("https://self-hosted.example.com/api")

      expect(described_class.new.api_endpoint).to eq(
        "https://self-hosted.example.com/api/v2/llm_request_templates"
      )
    end
  end

  describe "#search_templates" do
    context "with the request it builds" do
      before { stub_list(body: []) }

      it "sends the private API key and asks for JSON" do
        service.search_templates

        expect(WebMock).to have_requested(:get, endpoint)
          .with(headers: { "X-API-Key" => "test-private-key", "Accept" => "application/json" })
      end

      it "sends no query string when no filters are given" do
        service.search_templates

        expect(WebMock).to have_requested(:get, endpoint)
      end

      it "maps every keyword onto its wire parameter" do
        service.search_templates(
          search: "summar",
          workload_id: "w7x2mn4qk1zz",
          status: "published",
          include_deprecated: true,
          include_system: true,
          page: 2,
          per: 50
        )

        expect(WebMock).to have_requested(:get, endpoint).with(query: {
          "search" => "summar",
          "workload_id" => "w7x2mn4qk1zz",
          "status" => "published",
          "include_deprecated" => "true",
          "include_system" => "true",
          "page" => "2",
          "per" => "50"
        })
      end

      it "omits the filters that were not given" do
        service.search_templates(search: "summar")

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "search" => "summar" })
      end

      it "sends include_system=false rather than dropping an explicit false" do
        service.search_templates(include_system: false)

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "include_system" => "false" })
      end

      it "sends per and never per_page, since one knob is enough" do
        service.search_templates(per: 10)

        expect(WebMock).to(have_requested(:get, /llm_request_templates/).with do |req|
          expect(req.uri.query_values).to include("per" => "10")
          expect(req.uri.query_values).not_to have_key("per_page")
        end)
      end

      it "passes an unrecognised status straight through, leaving the 422 to the server" do
        service.search_templates(status: "bogus")

        expect(WebMock).to have_requested(:get, endpoint).with(query: { "status" => "bogus" })
      end

      it "rejects a client_id instead of sending one - the client comes from the API key" do
        expect { service.search_templates(client_id: "someone-else") }.to raise_error(ArgumentError, /client_id/)
        expect(WebMock).not_to have_requested(:get, /llm_request_templates/)
      end
    end

    context "with a successful response" do
      before { stub_list(body: [summary]) }

      it "returns the rows as Hashes with Symbol keys, matching the write methods" do
        result = service.search_templates

        expect(result.templates).to eq([summary])
      end

      it "keeps every field the definition declares, including system_template and log_count" do
        template = service.search_templates.templates.first

        expect(template).to include(
          id: "kp9npvc8qq2q",
          system_template: false,
          deprecated_at: nil,
          log_count: 42,
          workload_name: "Support"
        )
      end

      it "omits the prompt patterns, which come from #get_template only" do
        template = service.search_templates.templates.first

        expect(template).not_to have_key(:user_prompt_pattern)
        expect(template).not_to have_key(:system_prompt_pattern)
      end
    end

    describe "pagination" do
      it "is read from the response headers" do
        stub_list(
          body: [summary],
          headers: { "X-Page" => "3", "X-Per-Page" => "10", "X-Total-Count" => "97", "X-Total-Pages" => "10" }
        )

        expect(service.search_templates(page: 3, per: 10).pagination).to eq(
          Coolhand::Pagination.new(
            current_page: 3, per_page: 10, total_count: 97, total_pages: 10,
            has_next_page: true, has_prev_page: true
          )
        )
      end

      it "reports the server's total, not the size of the page in hand" do
        stub_list(
          body: [summary],
          headers: { "X-Page" => "1", "X-Per-Page" => "1", "X-Total-Count" => "97", "X-Total-Pages" => "97" }
        )

        expect(service.search_templates.pagination.total_count).to eq(97)
      end

      it "reads a total page count that disagrees with the total, rather than recomputing it" do
        stub_list(
          body: [],
          headers: { "X-Page" => "1", "X-Per-Page" => "25", "X-Total-Count" => "0", "X-Total-Pages" => "1" }
        )

        pagination = service.search_templates.pagination

        expect(pagination.total_pages).to eq(1)
        expect(pagination.has_next_page).to be(false)
        expect(pagination.has_prev_page).to be(false)
      end

      it "falls back to the requested page and defaults when the headers are absent" do
        stub_list(body: [summary], headers: {})

        expect(service.search_templates.pagination).to have_attributes(
          current_page: 1, per_page: 25, total_count: 1, total_pages: 1
        )
      end

      it "treats a malformed header as absent rather than as a real zero" do
        stub_list(
          body: [summary],
          headers: { "X-Page" => "1", "X-Per-Page" => "25", "X-Total-Count" => "not-a-number" }
        )

        expect(service.search_templates.pagination.total_count).to eq(1)
      end

      it "does not divide by a page size of zero if the server sends one" do
        stub_list(body: [summary], headers: { "X-Per-Page" => "0" })

        expect(service.search_templates.pagination).to have_attributes(
          per_page: 0, total_count: 1, total_pages: 1, has_next_page: false
        )
      end

      it "reports a next page when the totals are missing and the page came back full" do
        stub_list(body: Array.new(25) { summary }, headers: { "X-Page" => "1", "X-Per-Page" => "25" })

        expect(service.search_templates.pagination).to have_attributes(
          total_count: 25, has_next_page: true
        )
      end

      it "trusts the server page count over the totals when it sends one" do
        stub_list(
          body: Array.new(25) { summary },
          headers: pagination_headers.merge("X-Total-Count" => "100", "X-Total-Pages" => "1")
        )

        expect(service.search_templates.pagination.has_next_page).to be(false)
      end
    end

    describe "error handling" do
      it "does not follow a redirect, so the API key is never replayed to another host" do
        stub_list(body: {}, status: 302, headers: { "Location" => "https://elsewhere.example.com/" })

        expect { service.search_templates }.to raise_error(an_object_having_attributes(status: 302))
      end

      it "bounds the body it keeps, so a huge error page cannot ride on the exception" do
        stub_request(:get, /llm_request_templates/).to_return(status: 500, body: "x" * 20_000)

        expect { service.search_templates }
          .to raise_error(an_object_having_attributes(body: a_string_ending_with("... [truncated]")))
      end

      it "raises rather than returning nil, unlike the write methods" do
        stub_list(body: { error: "API key is required" }, status: 401)

        expect { service.search_templates }.to raise_error(Coolhand::HttpError)
      end

      it "carries 401 on the error so callers need not match on the message" do
        stub_list(body: { error: "Invalid API key" }, status: 401)

        expect { service.search_templates }.to raise_error(an_object_having_attributes(status: 401))
      end

      it "carries 422 for an unrecognised status filter" do
        stub_list(body: { errors: { status: ["must be one of: draft, published, failure"] } }, status: 422)

        expect { service.search_templates(status: "bogus") }
          .to raise_error(an_object_having_attributes(status: 422))
      end

      it "surfaces 504 as itself, since it is retryable rather than a generic server error" do
        stub_list(body: { errors: { system: ["Query timed out"] } }, status: 504)

        expect { service.search_templates }.to raise_error(an_object_having_attributes(status: 504))
      end

      it "keeps the response body on the error for diagnostics" do
        stub_list(body: { errors: { system: ["Query timed out"] } }, status: 504)

        expect { service.search_templates }
          .to raise_error(an_object_having_attributes(body: a_string_including("Query timed out")))
      end

      it "caps an oversized error body so it does not become the message" do
        stub_request(:get, /llm_request_templates/).to_return(status: 502, body: "x" * 5_000)

        expect { service.search_templates }
          .to raise_error(Coolhand::HttpError, /x{2000}\.\.\. \[truncated\]/)
      end

      it "raises when a 200 body parses but is not the array the endpoint documents" do
        stub_request(:get, /llm_request_templates/)
          .to_return(status: 200, body: "null", headers: { "Content-Type" => "application/json" })

        expect { service.search_templates }.to raise_error(Coolhand::Error, /not a JSON array/)
      end

      it "raises Coolhand::Error, not HttpError, when the body is not JSON" do
        stub_request(:get, /llm_request_templates/).to_return(status: 200, body: "<html>nope</html>")

        expect { service.search_templates }.to raise_error(Coolhand::Error, /not valid JSON/)
      end

      it "raises Coolhand::Error on a transport failure" do
        stub_request(:get, /llm_request_templates/).to_raise(Errno::ECONNREFUSED)

        expect { service.search_templates }.to raise_error(Coolhand::Error, /Template request failed/)
      end

      it "raises without making a request when no API key is configured" do
        allow(config).to receive(:api_key).and_return(nil)

        expect { service.search_templates }.to raise_error(Coolhand::Error, /API key is required/)
        expect(WebMock).not_to have_requested(:get, /llm_request_templates/)
      end
    end
  end

  describe "#get_template" do
    it "fetches the single resource by hashid" do
      stub_request(:get, "#{endpoint}/kp9npvc8qq2q")
        .to_return(status: 200, body: JSON.generate(detail), headers: { "Content-Type" => "application/json" })

      expect(service.get_template("kp9npvc8qq2q")).to eq(detail)
    end

    it "returns the prompt patterns the list omits" do
      stub_request(:get, "#{endpoint}/kp9npvc8qq2q")
        .to_return(status: 200, body: JSON.generate(detail), headers: { "Content-Type" => "application/json" })

      template = service.get_template("kp9npvc8qq2q")

      expect(template[:user_prompt_pattern]).to eq("\\ASummarise: (?<body>.+)\\z")
      expect(template).to have_key(:system_prompt_pattern)
    end

    it "sends the private API key" do
      stub_request(:get, "#{endpoint}/kp9npvc8qq2q").to_return(status: 200, body: "{}")

      service.get_template("kp9npvc8qq2q")

      expect(WebMock).to have_requested(:get, "#{endpoint}/kp9npvc8qq2q")
        .with(headers: { "X-API-Key" => "test-private-key" })
    end

    it "escapes an id so it cannot point the request at another resource" do
      stub_request(:get, %r{llm_request_templates/}).to_return(status: 200, body: "{}")

      service.get_template("../llm_request_logs")

      expect(WebMock).to(have_requested(:get, %r{llm_request_templates/}).with do |req|
        expect(req.uri.path).to eq("/api/v2/llm_request_templates/..%2Fllm_request_logs")
      end)
    end

    [nil, 42, "", "   ", ".", ".."].each do |bad_id|
      it "rejects #{bad_id.inspect} before building a request" do
        expect { service.get_template(bad_id) }.to raise_error(Coolhand::Error, /non-empty template hashid/)
        expect(WebMock).not_to have_requested(:get, /llm_request_templates/)
      end
    end

    it "carries 404 for an unknown id or one belonging to another client" do
      stub_request(:get, "#{endpoint}/zzz").to_return(
        status: 404,
        body: JSON.generate({ errors: { llmrequesttemplate: ["Couldn't find LlmRequestTemplate with id = zzz"] } })
      )

      expect { service.get_template("zzz") }.to raise_error(an_object_having_attributes(status: 404))
    end

    it "carries 504 on the log_count timeout" do
      stub_request(:get, "#{endpoint}/kp9npvc8qq2q")
        .to_return(status: 504, body: JSON.generate({ errors: { system: ["Query timed out"] } }))

      expect { service.get_template("kp9npvc8qq2q") }.to raise_error(an_object_having_attributes(status: 504))
    end
  end

  describe "Coolhand.template_service" do
    it "builds a TemplateService" do
      expect(Coolhand.template_service).to be_a(described_class)
    end
  end
end
