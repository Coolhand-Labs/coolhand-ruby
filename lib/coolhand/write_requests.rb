# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "errors"
require_relative "read_requests"

module Coolhand
  # POST/DELETE counterpart of {ReadRequests} for callers that act on the response: raises on any
  # failure where {ApiService#send_request} logs and returns nil. Timeouts are the read ones, for
  # the same server-side statement-bound reason.
  module WriteRequests
    protected

    # Returns the parsed body, or nil for an empty one (204).
    def request_json(verb, url, noun, body: nil)
      raise Error, "#{noun} request failed: an API key is required" unless Coolhand.required_field?(api_key)

      response = perform_write(verb, url, noun, body)

      unless response.is_a?(Net::HTTPSuccess)
        raise HttpError.new(
          "#{noun} request failed (#{response.code}): #{format_error_body(response.body)}",
          status: response.code.to_i,
          body: retained_error_body(response.body)
        )
      end

      response.body.to_s.strip.empty? ? nil : parse_json_body(response.body, noun)
    end

    private

    def perform_write(verb, url, noun, body)
      uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = ReadRequests::READ_OPEN_TIMEOUT
      http.read_timeout = ReadRequests::READ_TIMEOUT

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
