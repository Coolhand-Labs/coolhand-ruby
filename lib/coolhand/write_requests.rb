# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "errors"
require_relative "read_requests"

module Coolhand
  # POST/DELETE counterpart of {ReadRequests} for callers that act on the response: raises on any
  # failure where {ApiService#send_request} logs and returns nil. Timeouts are the read ones, for
  # the same server-side statement-bound reason. Mix into an {ApiService} subclass: it relies on
  # `api_key`, `apply_headers` and `format_error_body` from there and the shared HTTP helpers from
  # {ReadRequests}.
  module WriteRequests
    DOT_SEGMENTS = [".", ".."].freeze

    protected

    # Returns the parsed body, or nil for an empty one (204).
    def request_json(verb, url, noun, body: nil)
      raise Error, "#{noun} request failed: an API key is required" unless Coolhand.required_field?(api_key)

      response = perform_write(verb, url, noun, body)

      raise_http_error(response, noun) unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s.strip.empty? ? nil : parse_json_body(response.body, noun)
    end

    # `<endpoint>/by_key/<key>` for the upsert routes, which are globs: a key like "Parser#call/squish:L2"
    # keeps its slashes and each segment is escaped, so `#` or `?` in a key cannot retarget the request.
    def by_key_url(method_name, key)
      trimmed = key.is_a?(String) ? key.strip : ""
      segments = trimmed.split("/", -1)
      if trimmed.empty? || segments.any? { |segment| segment.empty? || DOT_SEGMENTS.include?(segment) }
        raise Error, "#{method_name}: key must be a non-empty string without empty or dot path segments"
      end

      URI.parse("#{api_endpoint}/by_key/#{segments.map { |segment| escape_path_segment(segment) }.join('/')}")
    end

    private

    def perform_write(verb, url, noun, body)
      uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
      http = build_http(uri)

      request = Net::HTTP.const_get(verb.to_s.capitalize).new(uri.request_uri)
      apply_headers(request, "Accept" => "application/json", "X-API-Key" => api_key)
      unless body.nil?
        apply_headers(request, "Content-Type" => "application/json")
        request.body = JSON.generate(body).force_encoding("UTF-8")
      end

      Coolhand.without_capture { http.request(request) }
    rescue StandardError => e
      raise Error, "#{noun} request failed: #{e.message}"
    end
  end
end
