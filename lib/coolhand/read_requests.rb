# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "errors"

module Coolhand
  # The GET half of {ApiService}, split out to keep that class inside this repo's 200-line budget.
  #
  # Reads raise where writes log-and-return-nil, on purpose: a write is instrumentation inline in
  # the host app's request, while a read's caller must tell a 404 from a timeout from an empty result.
  module ReadRequests
    # 60s is deliberate, not a slip: writes allow 5, but the server bounds each *statement* at 10s
    # and one response runs several. A tighter read timeout pre-empts the 504 callers should retry.
    READ_OPEN_TIMEOUT = 5
    READ_TIMEOUT = 60

    # ERROR_BODY_LIMIT caps the message; this caps the body the exception object itself carries.
    RETAINED_ERROR_BODY_LIMIT = 8_000

    protected

    def get_json(url, noun)
      body, = get_json_with_headers(url, noun)
      body
    end

    # Also returns the response, for endpoints that carry pagination in headers rather than the body.
    def get_json_with_headers(url, noun)
      raise Error, "#{noun} request failed: an API key is required" unless Coolhand.required_field?(api_key)

      response = perform_get(url, noun)

      unless response.is_a?(Net::HTTPSuccess)
        raise HttpError.new(
          "#{noun} request failed (#{response.code}): #{format_error_body(response.body)}",
          status: response.code.to_i,
          body: retained_error_body(response.body)
        )
      end

      [parse_json_body(response.body, noun), response]
    end

    private

    def perform_get(url, noun)
      uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = READ_OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Get.new(uri.request_uri)
      apply_headers(request, "Accept" => "application/json", "X-API-Key" => api_key)

      # Net::HTTP does not follow redirects, so a 3xx raises rather than replaying the API key at
      # an unapproved host. without_capture is the same recursion guard send_request uses.
      Coolhand.without_capture { http.request(request) }
    rescue StandardError => e
      raise Error, "#{noun} request failed: #{e.message}"
    end

    def retained_error_body(body)
      return body if body.nil? || body.length <= RETAINED_ERROR_BODY_LIMIT

      "#{body[0, RETAINED_ERROR_BODY_LIMIT]}... [truncated]"
    end

    def parse_json_body(body, noun)
      JSON.parse(body.to_s, symbolize_names: true)
    rescue JSON::ParserError
      raise Error, "#{noun} response was not valid JSON: #{format_error_body(body)}"
    end
  end
end
