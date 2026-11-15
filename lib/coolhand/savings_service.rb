# frozen_string_literal: true

require_relative "api_service"

module Coolhand
  # Reads the client's realized savings: a singleton keyed by the authenticating API key, with no id
  # and no filters. Requires the **private** key; the public key is rejected like an invalid one.
  # See docs/savings.md.
  class SavingsService < ApiService
    ERROR_NOUN = "Savings"

    def initialize
      super("v2/savings")
    end

    # What this client saved by switching templates or models: the cost of requests served by the
    # current templates versus the deprecated versions they replaced (deprecations in the last three
    # months, fixed server-side).
    #
    # Returns a Symbol-keyed Hash: `:total`, `:cost_at_previous_versions`, `:percent` and `:workloads`
    # (each row `:id`, `:name`, `:savings`, `:cost_at_previous_versions`, `:active_requests`). A client
    # with nothing to compare gets zeros and an empty `:workloads`, which is real zero savings.
    #
    # Raises {Coolhand::HttpError} on a non-2xx response: `401` for a missing, invalid or public key,
    # and `503` when the comparison could not be computed. A `503` is NOT zero savings; it is
    # retryable, so never map it to zeros.
    #
    # The name is the API definition's operationId; this is a network read, not an accessor.
    def get_realized_savings # rubocop:disable Naming/AccessorMethodName
      ensure_json_object!(get_json(api_endpoint, ERROR_NOUN), ERROR_NOUN)
    end
  end
end
