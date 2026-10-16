# frozen_string_literal: true

require_relative "api_service"
require_relative "pagination"
require_relative "read_query"
require_relative "write_requests"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  WorkloadSearchResult = Struct.new(:workloads, :pagination, keyword_init: true)

  # Lists workloads and upserts them by key. Requires the client's **private** key. There is no per-id
  # endpoint. See docs/workload-search.md and docs/declared_workloads.md.
  class WorkloadService < ApiService
    include ReadQuery
    include WriteRequests

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

    # Creates the workload with this `key`, or updates the existing one. The key is immutable; a new
    # `name` renames the display name. Returns the workload Hash (the server answers 201 on create,
    # 200 on update). Raises {Coolhand::HttpError} on a non-2xx response. See docs/declared_workloads.md.
    def upsert(key:, name: nil, description: nil, source: nil)
      body = { name: name, description: description, source: source }.compact
      request_json(:put, by_key_url("upsert", key), ERROR_NOUN, body: body)
    end
  end
end
