# frozen_string_literal: true

require_relative "api_service"
require_relative "pagination"
require_relative "read_query"

module Coolhand
  # Rows stay plain Symbol-keyed Hashes so a field the server adds later is not dropped in transit.
  LogSearchResult = Struct.new(:logs, :pagination, keyword_init: true)

  # Reads logs back out of Coolhand. The write side is {LoggerService}. Requires the client's
  # **private** key. See docs/log-search.md.
  class LogService < ApiService
    include ReadQuery

    ERROR_NOUN = "Log"
    BLANK_ID_MESSAGE = "get_log: id must be a non-empty log hashid"

    def initialize
      super("v2/llm_request_logs")
    end

    # Filters, cost ordering, error semantics and server behaviour: docs/log-search.md.
    def search_logs(template_id: nil, workload_id: nil, system_prompt_contains: nil, user_prompt_contains: nil,
      model: nil, source_api: nil, source_api_result: nil, source_application: nil, project_path: nil,
      unmatched_only: nil, days_back: nil, since: nil, until: nil, min_cost: nil, order: nil,
      include_prompts: nil, include_total: nil, sort: nil, page: nil, per: nil)
      query = {
        template_id: template_id,
        workload_id: workload_id,
        system_prompt_contains: system_prompt_contains,
        user_prompt_contains: user_prompt_contains,
        model: model,
        source_api: source_api,
        source_api_result: source_api_result,
        source_application: source_application,
        project_path: project_path,
        unmatched_only: unmatched_only,
        days_back: days_back,
        **window_params(since, binding.local_variable_get(:until)),
        min_cost: min_cost,
        order: order,
        include_prompts: include_prompts,
        include_total: include_total,
        "q[s]": sort,
        page: page,
        per: per
      }.compact

      logs, response = get_json_with_headers(list_url(query), ERROR_NOUN)
      raise Error, "#{ERROR_NOUN} response was not a JSON array" unless logs.is_a?(Array)

      LogSearchResult.new(
        logs: logs,
        pagination: Pagination.from_headers(response, items: logs, page: page, per: per)
      ).freeze
    end

    # The full log, with `cost` and `cost_breakdown`. Both are nil when the log has no tokens or its
    # model has no pricing.
    def get_log(id, section: nil, max_chars: nil, search_query: nil, include_thinking: nil)
      query = { section: section, max_chars: max_chars, search_query: search_query,
                include_thinking: include_thinking }.compact
      get_json(resource_url(id, BLANK_ID_MESSAGE, query), ERROR_NOUN)
    end
  end
end
