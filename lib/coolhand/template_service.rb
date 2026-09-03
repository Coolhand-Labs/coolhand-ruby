# frozen_string_literal: true

require "uri"
require_relative "api_service"
require_relative "pagination"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  TemplateSearchResult = Struct.new(:templates, :pagination, keyword_init: true)

  # Read-only. Requires the client's **private** key — the public key is write-only here and is
  # rejected like an invalid one.
  #
  # Not a port of the MCP `search_templates` tool and does not agree with its `log_count`.
  # See docs/template-search.md.
  class TemplateService < ApiService
    ERROR_NOUN = "Template"
    BLANK_ID_MESSAGE = "get_template: id must be a non-empty template hashid"

    def initialize
      super("v2/llm_request_templates")
    end

    # Filters, error semantics and server behaviour: docs/template-search.md.
    def search_templates(search: nil, workload_id: nil, status: nil, include_deprecated: nil,
      include_system: nil, page: nil, per: nil)
      query = {
        search: search,
        workload_id: workload_id,
        status: status,
        include_deprecated: include_deprecated,
        include_system: include_system,
        page: page,
        per: per
      }.compact

      templates, response = get_json_with_headers(list_url(query), ERROR_NOUN)
      raise Error, "#{ERROR_NOUN} response was not a JSON array" unless templates.is_a?(Array)

      TemplateSearchResult.new(
        templates: templates,
        pagination: Pagination.from_headers(response, items: templates, page: page, per: per)
      ).freeze
    end

    # Adds `user_prompt_pattern` / `system_prompt_pattern`, which the list omits, and unlike the
    # list reaches deprecated and system templates by id with no opt-in flag.
    def get_template(id)
      get_json(resource_url(id), ERROR_NOUN)
    end

    private

    def list_url(query)
      uri = URI.parse(api_endpoint)
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    def resource_url(id)
      raise Error, BLANK_ID_MESSAGE unless id.is_a?(String)

      trimmed = id.strip
      # A blank id resolves to the index route (bare array, not one template); a bare dot segment
      # retargets the request at another path. Neither would 404, so both are rejected here.
      raise Error, BLANK_ID_MESSAGE if trimmed.empty? || [".", ".."].include?(trimmed)

      URI.parse("#{api_endpoint}/#{escape_path_segment(trimmed)}")
    end

    # Escapes to RFC 3986 unreserved, so an id carrying `/`, `?` or `#` cannot retarget the request.
    def escape_path_segment(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end
  end
end
