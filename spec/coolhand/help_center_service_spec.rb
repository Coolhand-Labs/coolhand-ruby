# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::HelpCenterService do
  let(:endpoint) { "https://coolhandlabs.com/api/v2/public_content" }
  let(:api_key) { nil }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: api_key,
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }

  # Every field the API definition declares on the list response, nullable ones included.
  let(:summary) do
    {
      slug: "what-is-feedback-match-rate",
      title: "What is feedback match rate?",
      answer: nil,
      article_kind: "concept",
      tags: %w[feedback matching],
      category: "feedback-and-prompts",
      url: "https://coolhandlabs.com/help/what-is-feedback-match-rate",
      markdown_url: "https://coolhandlabs.com/help/what-is-feedback-match-rate.md",
      reading_time_minutes: nil,
      search_headline: nil,
      published_at: "2026-08-30T13:57:52Z",
      updated_content_at: nil
    }
  end
  let(:article) do
    summary.except(:search_headline).merge(
      body: "# Match rate\n\nBody.",
      noindex: false,
      toc: [{ id: "match-rate", text: "Match rate", level: 2, children: [] }]
    )
  end
  let(:pagination_headers) do
    { "X-Page" => "2", "X-Per-Page" => "10", "X-Total-Count" => "25", "X-Total-Pages" => "3" }
  end

  before { allow(Coolhand).to receive(:configuration).and_return(config) }

  def stub_json(url, body, status: 200, headers: {})
    stub_request(:get, url).to_return(
      status: status,
      body: JSON.generate(body),
      headers: headers.merge("Content-Type" => "application/json")
    )
  end

  describe "Coolhand.help_center_service" do
    it "builds the service" do
      expect(Coolhand.help_center_service).to be_a(described_class)
    end
  end

  describe "#initialize" do
    it "hangs off the public_content collection on the configured base_url" do
      expect(service.api_endpoint).to eq(endpoint)
    end
  end

  describe "authentication" do
    before { stub_json(/public_content/, []) }

    context "with no key configured" do
      it "makes the call and sends no X-API-Key header at all" do
        expect { service.search_help_articles }.not_to raise_error

        expect(WebMock).to(have_requested(:get, endpoint).with { |req| !req.headers.key?("X-Api-Key") })
      end

      it "treats a blank key the same as no key" do
        allow(config).to receive(:api_key).and_return("   ")

        service.list_help_categories

        expect(WebMock).to(have_requested(:get, "#{endpoint}/categories").with { |req| !req.headers.key?("X-Api-Key") })
      end
    end

    context "with a configured key" do
      let(:api_key) { "test-key" }

      it "sends it as X-API-Key on every call" do
        stub_json("#{endpoint}/some-slug", article)

        service.search_help_articles
        service.get_help_article("some-slug")
        service.list_help_categories

        expect(WebMock).to have_requested(:get,
          /public_content/).with(headers: { "X-API-Key" => "test-key" }).times(3)
      end
    end

    context "when the server rejects the key" do
      let(:api_key) { "bad-key" }

      it "raises a 401 HttpError rather than retrying anonymously" do
        stub_json(/public_content/, { error: "Invalid API key." }, status: 401)

        expect { service.search_help_articles }.to raise_error(Coolhand::HttpError) { |e|
          expect(e.status).to eq(401)
          expect(e.body).to include("Invalid API key.")
        }
        expect(WebMock).to have_requested(:get, /public_content/).once
      end
    end
  end

  describe "#search_help_articles" do
    it "lists with no query string and asks for JSON" do
      stub_json(endpoint, [summary])

      result = service.search_help_articles

      expect(WebMock).to have_requested(:get, endpoint).with(headers: { "Accept" => "application/json" })
      expect(result.articles).to eq([summary])
    end

    it "sends a plain q for a query alone" do
      stub_json(/public_content/, [])

      service.search_help_articles(query: "match rate")

      expect(WebMock).to have_requested(:get, endpoint).with(query: { "q" => "match rate" })
    end

    it "sends the structured category filter for a category alone" do
      stub_json(/public_content/, [])

      service.search_help_articles(category: "providers")

      expect(WebMock).to have_requested(:get, endpoint).with(query: { "q[help_category_slug_eq]" => "providers" })
    end

    it "moves the query to q[full_text] when a category is also given" do
      stub_json(/public_content/, [])

      service.search_help_articles(query: "anthropic", category: "providers")

      expect(WebMock).to have_requested(:get, endpoint).with(
        query: { "q[help_category_slug_eq]" => "providers", "q[full_text]" => "anthropic" }
      )
    end

    it "percent-encodes the bracket keys and never sends the plain q alongside them" do
      stub_json(/public_content/, [])
      allow(Net::HTTP::Get).to receive(:new).and_call_original

      service.search_help_articles(query: "anthropic", category: "providers")

      expect(Net::HTTP::Get).to have_received(:new)
        .with("/api/v2/public_content?q%5Bhelp_category_slug_eq%5D=providers&q%5Bfull_text%5D=anthropic")
    end

    it "treats a blank query or category as omitted" do
      stub_json(/public_content/, [])

      service.search_help_articles(query: "  ", category: "")

      expect(WebMock).to(have_requested(:get, endpoint).with { |req| req.uri.query.nil? })
    end

    it "sends page and per_page, and never per" do
      stub_json(/public_content/, [])

      service.search_help_articles(page: 2, per_page: 10)

      expect(WebMock).to have_requested(:get, endpoint).with(query: { "page" => "2", "per_page" => "10" })
    end

    it "parses the pagination headers" do
      stub_json(/public_content/, [summary], headers: pagination_headers)

      pagination = service.search_help_articles(query: "match", page: 2, per_page: 10).pagination

      expect(pagination).to have_attributes(
        current_page: 2, per_page: 10, total_count: 25, total_pages: 3, has_next_page: true, has_prev_page: true
      )
    end

    it "keeps a search_headline and the nullable fields as the server sent them" do
      row = summary.merge(search_headline: "<mark>Match</mark> rate")
      stub_json(/public_content/, [row])

      expect(service.search_help_articles(query: "match").articles.first).to include(
        search_headline: "<mark>Match</mark> rate", answer: nil, reading_time_minutes: nil, updated_content_at: nil
      )
    end

    it "raises a 429 HttpError when the anonymous limit is exceeded" do
      stub_json(/public_content/, { error: "Rate limit exceeded" }, status: 429)

      expect { service.search_help_articles }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(429) }
    end

    it "raises Coolhand::Error when the body is not a JSON array" do
      stub_json(/public_content/, { not: "an array" })

      expect { service.search_help_articles }.to raise_error(Coolhand::Error, /not a JSON array/)
    end
  end

  describe "#get_help_article" do
    it "returns the article with its markdown body" do
      stub_json("#{endpoint}/what-is-feedback-match-rate", article)

      result = service.get_help_article("what-is-feedback-match-rate")

      expect(result).to include(body: "# Match rate\n\nBody.", noindex: false, toc: [include(id: "match-rate")])
      expect(result).not_to have_key(:search_headline)
    end

    it "percent-encodes the slug as a single path segment" do
      stub_json(/public_content/, article)

      service.get_help_article("a/b?c#d")

      expect(WebMock).to have_requested(:get, "#{endpoint}/a%2Fb%3Fc%23d")
    end

    it "raises a 404 HttpError for an unknown slug" do
      stub_request(:get, "#{endpoint}/nope").to_return(status: 404, body: "")

      expect { service.get_help_article("nope") }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(404) }
    end

    [nil, "", "   ", ".", "..", 42].each do |slug|
      it "rejects #{slug.inspect} before any request" do
        expect { service.get_help_article(slug) }.to raise_error(Coolhand::Error, /slug must be a non-empty string/)
        expect(WebMock).not_to have_requested(:get, /public_content/)
      end
    end
  end

  describe "#list_help_categories" do
    let(:categories) do
      [
        { slug: "providers", name: "Providers", description: "Guides", url_prefix: "/help", allowed_tags: nil },
        { slug: "updates", name: "Updates", description: "News", url_prefix: "/updates", allowed_tags: %w[release] }
      ]
    end

    it "returns the sections as the server sent them" do
      stub_json("#{endpoint}/categories", categories)

      expect(service.list_help_categories).to eq(categories)
    end

    it "does not mistake categories for a slug" do
      stub_json("#{endpoint}/categories", categories)

      service.list_help_categories

      expect(WebMock).to have_requested(:get, "#{endpoint}/categories").once
    end
  end

  describe "existing read services" do
    it "still require a key" do
      expect { Coolhand::WorkloadService.new.search_workloads }
        .to raise_error(Coolhand::Error, /an API key is required/)
    end
  end
end
