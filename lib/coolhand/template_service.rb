# frozen_string_literal: true

require "uri"
require_relative "api_service"
require_relative "pagination"

module Coolhand
  # What {TemplateService#search_templates} returns: the page of templates, and the
  # {Coolhand::Pagination} describing where that page sits.
  #
  # The rows themselves stay as plain Hashes with Symbol keys — the same shape `create_feedback`
  # and `create_log` already return — rather than being wrapped in a value object. Wrapping would
  # mean enumerating the fields client-side, and any field the server adds later would be silently
  # dropped on the way through.
  TemplateSearchResult = Struct.new(:templates, :pagination, keyword_init: true)

  # Read-only access to `GET /api/v2/llm_request_templates` and
  # `GET /api/v2/llm_request_templates/{id}`.
  #
  # Both require the client's **private** API key. The public key is write-only on this API and is
  # rejected exactly like an invalid one.
  #
  # Both raise on failure rather than logging and returning `nil` the way this gem's write methods
  # do: a caller reading data has to be able to tell a 404 from a timeout from an empty result. See
  # {Coolhand::HttpError}.
  #
  # Template *mutation* stays on the MCP surface — there is no create, update or deprecate here,
  # and no version-history sub-resource.
  #
  # This is **not** a port of the `search_templates` MCP tool and does not agree with its numbers:
  # `log_count` here counts only directly-collected client logs, and templates whose workload has
  # been archived are returned rather than hidden.
  class TemplateService < ApiService
    ERROR_NOUN = "Template"
    BLANK_ID_MESSAGE = "get_template: id must be a non-empty template hashid"

    def initialize
      super("v2/llm_request_templates")
    end

    # List templates, newest first (`created_at DESC`, with a primary-key tiebreaker so paging is
    # stable across requests).
    #
    # Search is a *parameter* on the list endpoint rather than a route of its own, so this is one
    # method rather than a list/search pair.
    #
    # The keyword names are the wire names deliberately: Ruby's convention and this API's already
    # agree, so there is no second spelling to translate through.
    #
    # There is no `client_id` keyword. The client is always derived from the authenticating API key
    # and cannot be supplied, so passing one raises `ArgumentError` here rather than reaching the
    # wire.
    #
    # @param search [String, nil] case-insensitive *literal* substring match on the template name.
    #   `%` and `_` are escaped server-side and match themselves — do not escape them again.
    # @param workload_id [String, nil] workload hashid. One that does not decode, or that belongs
    #   to another client, is a 422 rather than an empty list.
    # @param status [String, nil] `"draft"`, `"published"` or `"failure"`. Any other non-empty
    #   value is a 422 from the server; empty is treated as no filter. Not checked here, so a
    #   status the server gains later works without a gem release.
    # @param include_deprecated [Boolean, nil] include templates with a non-null `deprecated_at`.
    #   Defaults to false server-side.
    # @param include_system [Boolean, nil] include the `Unmatched` / `Ignored API Calls` buckets
    #   every client is created with. Defaults to false server-side, which is why a client with no
    #   templates of its own gets an empty array rather than those two rows.
    # @param page [Integer, nil] 1-based page number.
    # @param per [Integer, nil] page size (default 25, max 100, both enforced server-side).
    #   `per_page` is accepted on the wire as an alias, but one knob is enough, so only `per` is
    #   sent.
    #
    # @return [TemplateSearchResult] `templates` are Hashes with Symbol keys; `pagination` is read
    #   from the response headers, which this endpoint always sends.
    # @raise [Coolhand::HttpError] on a non-2xx response, carrying `status`: 401 for a missing,
    #   invalid or public key; 422 for an unrecognised `status` or a bad `workload_id`; 504 when
    #   the `log_count` aggregate exceeds the server's statement timeout. A 504 is expected and
    #   retryable — narrow with `workload_id`, `search` or a smaller `per` and try again.
    # @raise [Coolhand::Error] when the API key is missing, on a transport failure, or on a body
    #   that is not valid JSON.
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

      TemplateSearchResult.new(
        templates: templates,
        pagination: Pagination.from_headers(response, items: templates, page: page, per: per)
      )
    end

    # Fetch one template by hashid, including `user_prompt_pattern` and `system_prompt_pattern` —
    # the full untruncated regexes {#search_templates} omits.
    #
    # Unlike the list, this filters on nothing but client ownership: a deprecated or system
    # template is reachable by id with no opt-in flag, because inspecting one of those is the usual
    # reason to fetch a template directly.
    #
    # @param id [String] the template hashid, i.e. the `:id` field from {#search_templates}.
    # @return [Hash] the template, with Symbol keys.
    # @raise [Coolhand::HttpError] on a non-2xx response, carrying `status`: 404 for an unknown id
    #   *or* one belonging to another client — existence is not disclosed, so this is never a 403 —
    #   and 504 on the same `log_count` timeout described on {#search_templates}, which fetching
    #   the `Unmatched` bucket by id is the most likely way to hit.
    # @raise [Coolhand::Error] when `id` is blank or a bare dot segment, when the API key is
    #   missing, on a transport failure, or on a body that is not valid JSON.
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
      # A blank id resolves away to the index route, which would hand back a bare array where the
      # caller expects one template; a bare dot segment retargets the request at another path
      # entirely. Neither would 404, so both are rejected before the request is built.
      raise Error, BLANK_ID_MESSAGE if trimmed.empty? || [".", ".."].include?(trimmed)

      URI.parse("#{api_endpoint}/#{escape_path_segment(trimmed)}")
    end

    # Percent-escapes everything outside RFC 3986's unreserved set, so an id carrying `/`, `?` or
    # `#` cannot point the request at a different resource.
    def escape_path_segment(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end
  end
end
