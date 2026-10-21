# frozen_string_literal: true

require_relative "api_service"
require_relative "pagination"
require_relative "read_query"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  HelpArticleSearchResult = Struct.new(:articles, :pagination, keyword_init: true)

  # Read-only access to the Coolhand help center: the `public_content` endpoints (`GET /api/v2/public_content`,
  # `/:slug` and `/categories`), the same pages served at `/help/:slug` and `/updates/:slug`. Create, update and
  # archive are Coolhand-internal and not wrapped.
  #
  # Unlike every other service this one needs no API key. A configured `api_key` is sent as `X-API-Key` and lifts
  # the anonymous limit of 30 requests per minute per IP (429 beyond); with none, no key header is sent. A key the
  # server rejects raises a 401 {Coolhand::HttpError}; it is not retried anonymously. See docs/help-center.md.
  class PublicContentService < ApiService
    include ReadQuery

    ERROR_NOUN = "Help center"
    BLANK_SLUG_MESSAGE = "get_help_article: slug must be a non-empty string"

    def initialize
      super("v2/public_content")
    end

    # Relevance search with `query`, a full listing without. `category` filters to one section slug; the
    # endpoint has no such parameter, so it is sent as `q[help_category_slug_eq]` and `query` moves to
    # `q[full_text]` (the plain `q` string and the `q[...]` form cannot be mixed). A blank `query` or
    # `category` counts as omitted. Returns a {HelpArticleSearchResult}; raises {Coolhand::HttpError} on a
    # non-2xx response.
    def search_help_articles(query: nil, category: nil, page: nil, per_page: nil)
      params = { **search_params(query, category), page: page, per_page: per_page }.compact

      fetch_list(params, HelpArticleSearchResult, :articles, page: page, per: per_page)
    end

    # One published article with its markdown `body`, `noindex` and `toc`. Raises {Coolhand::Error} before any
    # request for a blank slug, and {Coolhand::HttpError} (404) for an unknown or unpublished one.
    def get_help_article(slug)
      get_json(resource_url(slug, BLANK_SLUG_MESSAGE), ERROR_NOUN)
    end

    # Every section an article can be filed under, with its `url_prefix` and `allowed_tags`.
    def list_help_categories
      get_json(URI.parse("#{api_endpoint}/categories"), ERROR_NOUN)
    end

    protected

    def api_key_required?
      false
    end

    private

    def search_params(query, category)
      query = nil if omitted?(query)
      return { q: query } if omitted?(category)

      { "q[help_category_slug_eq]": category, "q[full_text]": query }
    end

    def omitted?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
