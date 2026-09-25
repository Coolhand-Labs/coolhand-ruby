# frozen_string_literal: true

require "uri"
require_relative "api_service"
require_relative "write_requests"

module Coolhand
  # Requires the client's **private** key; the public key gets a 401. Unlike the logging writes,
  # every method raises {Coolhand::Error} / {Coolhand::HttpError} on failure. See docs/feedback-links.md.
  class OptimizationFeedbackLinkService < ApiService
    include WriteRequests

    ERROR_NOUN = "Feedback link"
    # The server rejects more ids than this per request with a 422.
    BULK_BATCH_SIZE = 100

    def initialize
      super("v2/optimizations")
    end

    # Returns `{ id:, optimization_id:, feedback_id:, note:, created_at: }`; `id` is the link's hashid.
    def link_feedback(optimization_id, feedback_id, note: nil)
      validate_id!("link_feedback", "feedback_id", feedback_id)
      url = links_url("link_feedback", optimization_id)
      request_json(:post, url, ERROR_NOUN, body: { feedback_id: feedback_id, note: note }.compact)
    end

    # Lists over 100 ids are sent in batches; a failing batch raises and earlier ones stay applied,
    # so repeating the call is safe. Returns `{ linked:, already_linked:, errored:, not_found: }` summed
    # across batches.
    def bulk_link_feedback(optimization_id, feedback_ids, note: nil)
      unless feedback_ids.is_a?(Array) && !feedback_ids.empty?
        raise Error, "bulk_link_feedback: feedback_ids must be a non-empty array of hashids"
      end

      feedback_ids.each { |id| validate_id!("bulk_link_feedback", "feedback_ids entries", id) }
      url = links_url("bulk_link_feedback", optimization_id)

      totals = { linked: 0, already_linked: 0, errored: 0, not_found: [] }
      feedback_ids.each_slice(BULK_BATCH_SIZE) do |batch|
        result = request_json(:post, url, ERROR_NOUN, body: { feedback_ids: batch, note: note }.compact)
        merge_bulk_result!(totals, result)
      end
      totals
    end

    # `link_id` is the `id` returned by {#link_feedback}, not the feedback's. Returns true.
    def unlink_feedback(optimization_id, link_id)
      validate_id!("unlink_feedback", "link_id", link_id)
      url = URI.parse("#{links_url('unlink_feedback', optimization_id)}/#{escape_path_segment(link_id.strip)}")
      request_json(:delete, url, ERROR_NOUN)
      true
    end

    private

    def merge_bulk_result!(totals, result)
      raise Error, "#{ERROR_NOUN} response was not a JSON object" unless result.is_a?(Hash)

      %i[linked already_linked errored].each { |key| totals[key] += result[key].to_i }
      totals[:not_found].concat(Array(result[:not_found]))
    end

    def links_url(method_name, optimization_id)
      validate_id!(method_name, "optimization_id", optimization_id)
      URI.parse("#{api_endpoint}/#{escape_path_segment(optimization_id.strip)}/feedback_links")
    end

    # A blank id would resolve to a different route and a bare dot segment would retarget the
    # request; neither 404s, so both are rejected before any request is made.
    def validate_id!(method_name, label, value)
      trimmed = value.is_a?(String) ? value.strip : ""
      return unless trimmed.empty? || [".", ".."].include?(trimmed)

      raise Error, "#{method_name}: #{label} must be a non-empty hashid"
    end

    def escape_path_segment(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end
  end
end
