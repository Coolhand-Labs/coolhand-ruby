# frozen_string_literal: true

require_relative "api_service"
require_relative "pagination"
require_relative "read_query"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  StepTemplateSearchResult = Struct.new(:step_templates, :pagination, keyword_init: true)

  # Reads the skills and other recurring steps Coolhand detects in captured agent sessions. Read-only;
  # there are no write endpoints. Requires the client's **private** key — the public key is rejected
  # like an invalid one. See docs/step-templates.md.
  class StepTemplateService < ApiService
    include ReadQuery

    ERROR_NOUN = "Step template"
    INVALID_ID_MESSAGE = "get_step_template: id must be a positive Integer"

    def initialize
      super("v2/step_templates")
    end

    # Filters, `metrics` and error semantics: docs/step-templates.md.
    def list_step_templates(search: nil, step_type: nil, include_metrics: nil, page: nil, per: nil)
      query = {
        search: search,
        step_type: step_type,
        include_metrics: include_metrics,
        page: page,
        per: per
      }.compact

      fetch_list(query, StepTemplateSearchResult, :step_templates, page: page, per: per)
    end

    # Carries `metrics` unless `include_metrics: false`, the opposite default from the list.
    def get_step_template(id, include_metrics: nil)
      raise Error, INVALID_ID_MESSAGE unless id.is_a?(Integer) && id.positive?

      query = { include_metrics: include_metrics }.compact
      get_json(resource_url(id.to_s, INVALID_ID_MESSAGE, query), ERROR_NOUN)
    end
  end
end
