# frozen_string_literal: true

require_relative "api_service"
require_relative "pagination"
require_relative "read_query"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  TemplateSearchResult = Struct.new(:templates, :pagination, keyword_init: true)

  # Read-only. Requires the client's **private** key — the public key is write-only here and is
  # rejected like an invalid one.
  #
  # Not a port of the MCP `search_templates` tool and does not agree with its `log_count`.
  # See docs/template-search.md.
  class TemplateService < ApiService
    include ReadQuery

    ERROR_NOUN = "Template"
    BLANK_ID_MESSAGE = "get_template: id must be a non-empty template hashid"

    def initialize
      super("v2/llm_request_templates")
    end

    # Filters, error semantics and server behaviour: docs/template-search.md.
    def search_templates(search: nil, workload_id: nil, status: nil, include_deprecated: nil,
      include_system: nil, include_metrics: nil, days_back: nil, since: nil, until: nil, page: nil, per: nil)
      query = {
        search: search,
        workload_id: workload_id,
        status: status,
        include_deprecated: include_deprecated,
        include_system: include_system,
        include_metrics: include_metrics,
        days_back: days_back,
        **window_params(since, binding.local_variable_get(:until)),
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
    # list reaches deprecated and system templates by id with no opt-in flag. Carries `metrics`
    # unless `include_metrics: false`, which also skips the window validation.
    def get_template(id, include_metrics: nil, days_back: nil, since: nil, until: nil)
      query = { include_metrics: include_metrics, days_back: days_back,
                **window_params(since, binding.local_variable_get(:until)) }.compact
      get_json(resource_url(id, BLANK_ID_MESSAGE, query), ERROR_NOUN)
    end
  end
end
