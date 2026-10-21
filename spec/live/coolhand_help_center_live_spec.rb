# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# Read-only, key-less calls against a running Coolhand server. Not part of the default run: set
#   COOLHAND_SPEC_LIVE_BASE_URL=http://127.0.0.1:3000/api
# to exercise it. Makes about nine anonymous requests, so repeated runs within a minute can hit the
# 30/min/IP limit (429). Creates and mutates nothing.
HELP_CENTER_LIVE = !ENV.fetch("COOLHAND_SPEC_LIVE_BASE_URL", "").strip.empty?

RSpec.describe Coolhand, if: HELP_CENTER_LIVE do
  let(:service) { Coolhand.help_center_service }

  before do
    WebMock.allow_net_connect!
    Coolhand.configure do |config|
      config.base_url = ENV.fetch("COOLHAND_SPEC_LIVE_BASE_URL")
      config.silent = true
      config.enabled = false
    end
  end

  after { WebMock.disable_net_connect! }

  it "runs with no key configured" do
    expect(Coolhand.configuration.api_key).to be_nil

    result = service.search_help_articles(per_page: 3)

    expect(result.articles.size).to be_between(1, 3)
    expect(result.articles.first).to include(:slug, :title, :answer, :category, :url, :markdown_url)
    expect(result.articles.first).not_to have_key(:body)
    expect(result.pagination).to have_attributes(per_page: 3, current_page: 1, has_next_page: true)
    expect(result.pagination.total_count).to be > 3
  end

  it "returns a search_headline on a q search" do
    result = service.search_help_articles(query: "feedback", per_page: 3)

    expect(result.articles.first[:search_headline]).to include("<mark>")
  end

  it "filters by category with the structured form, alone and with a query" do
    by_category = service.search_help_articles(category: "providers", per_page: 100)
    narrowed = service.search_help_articles(category: "providers", query: "anthropic", per_page: 100)

    expect(by_category.articles.map { |a| a[:category] }.uniq).to eq(["providers"])
    expect(narrowed.pagination.total_count).to be_between(1, by_category.pagination.total_count - 1)
  end

  it "fetches one article by slug with its markdown body" do
    slug = service.search_help_articles(per_page: 1).articles.first[:slug]

    article = service.get_help_article(slug)

    expect(article).to include(slug: slug, noindex: be(true).or(be(false)))
    expect(article[:body]).to be_a(String).and(satisfy { |body| !body.empty? })
    expect(article[:toc]).to be_an(Array)
  end

  it "raises a 404 for an unknown slug" do
    expect { service.get_help_article("no-such-article-slug") }
      .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(404) }
  end

  it "lists the sections" do
    categories = service.list_help_categories

    expect(categories).to include(a_hash_including(slug: "providers", url_prefix: "/help"))
    expect(categories.map { |c| c[:url_prefix] } - ["/help", "/updates"]).to be_empty
  end

  it "raises 401 for an invalid key rather than falling back to anonymous" do
    Coolhand.configuration.api_key = "not-a-real-key"

    expect { service.list_help_categories }
      .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(401) }
  end
end
