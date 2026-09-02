# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "errors"

module Coolhand
  # The GET half of {ApiService}, kept in its own file so the class stays inside this repo's
  # 200-line budget. Written as a mixin for {ApiService} specifically: it leans on that class's
  # `api_key`, `apply_headers` and `format_error_body`, which the POST half uses too.
  #
  # The two halves differ on purpose. A write is instrumentation running inline in the host app's
  # own request, so it logs a failure and returns `nil` — Coolhand must never be the reason an app
  # falls over. A read was asked for by the caller, who has to be able to tell a 404 from a
  # timeout from a genuinely empty result, so it raises.
  module ReadRequests
    # Stops a hung connection blocking a caller forever, without cutting a working request short.
    #
    # Deliberately far longer than the 5s the write path allows: a write is instrumentation running
    # inline in the host app's own request, while a read is something the caller asked for and is
    # waiting on. The API bounds each *statement* behind a response at 10 seconds and answers 504
    # past that, but one response runs several statements, so total time is not bounded by 10s:
    # GET /api/v2/llm_request_templates?include_system=true measured 7-15 seconds against a
    # development database while returning 200 every time. A tighter read timeout reports a working
    # endpoint as a transport failure, and pre-empts the 504 callers are meant to see and retry.
    READ_OPEN_TIMEOUT = 5
    READ_TIMEOUT = 60

    protected

    # GET +url+ and parse the JSON body, raising on any failure.
    #
    # @param noun [String] capitalised subject prefixing error messages, e.g. "Template".
    # @raise [Coolhand::HttpError] on a non-2xx response, carrying the status code.
    # @raise [Coolhand::Error] when the API key is missing, on a transport failure, or on a body
    #   that is not valid JSON.
    def get_json(url, noun)
      body, = get_json_with_headers(url, noun)
      body
    end

    # As {#get_json}, but also hands back the Net::HTTPResponse, for endpoints whose answer is
    # partly in the headers - the v2 list endpoints carry pagination there, not in the body.
    #
    # @return [Array(Object, Net::HTTPResponse)]
    def get_json_with_headers(url, noun)
      raise Error, "#{noun} request failed: an API key is required" unless Coolhand.required_field?(api_key)

      response = perform_get(url, noun)

      unless response.is_a?(Net::HTTPSuccess)
        raise HttpError.new(
          "#{noun} request failed (#{response.code}): #{format_error_body(response.body)}",
          status: response.code.to_i,
          body: response.body
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

      # Net::HTTP does not follow redirects, so a 3xx surfaces as an HttpError rather than
      # silently replaying the API key against a host the configured base_url never approved.
      # without_capture is the same recursion guard send_request uses: a base_url or
      # intercept_addresses entry that also matches Coolhand's own host would otherwise make
      # this call get logged, and that log call get logged, without bound.
      Coolhand.without_capture { http.request(request) }
    rescue StandardError => e
      raise Error, "#{noun} request failed: #{e.message}"
    end

    def parse_json_body(body, noun)
      JSON.parse(body.to_s, symbolize_names: true)
    rescue JSON::ParserError
      raise Error, "#{noun} response was not valid JSON: #{format_error_body(body)}"
    end
  end
end
