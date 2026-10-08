# frozen_string_literal: true

require_relative "api_service"
require_relative "pagination"
require_relative "read_query"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  WorkloadSearchResult = Struct.new(:workloads, :pagination, keyword_init: true)

  # Read-only. Requires the client's **private** key. There is no per-id endpoint.
  # See docs/workload-search.md.
  class WorkloadService < ApiService
    include ReadQuery

    ERROR_NOUN = "Workload"

    def initialize
      super("v2/workloads")
    end

    # Filters, windows, error semantics and server behaviour: docs/workload-search.md.
    def search_workloads(search: nil, include_archived: nil, include_system: nil, include_templates: nil,
      include_metrics: nil, days_back: nil, since: nil, until: nil, page: nil, per: nil)
      query = {
        search: search,
        include_archived: include_archived,
        include_system: include_system,
        include_templates: include_templates,
        include_metrics: include_metrics,
        days_back: days_back,
        **window_params(since, binding.local_variable_get(:until)),
        page: page,
        per: per
      }.compact

      workloads, response = get_json_with_headers(list_url(query), ERROR_NOUN)
      raise Error, "#{ERROR_NOUN} response was not a JSON array" unless workloads.is_a?(Array)

      WorkloadSearchResult.new(
        workloads: workloads,
        pagination: Pagination.from_headers(response, items: workloads, page: page, per: per)
      ).freeze
    end
  end
end
