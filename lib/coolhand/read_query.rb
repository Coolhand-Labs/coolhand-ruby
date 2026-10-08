# frozen_string_literal: true

require "date"
require "time"
require "uri"
require_relative "errors"

module Coolhand
  # URL building shared by the read services. Everything goes through `URI.encode_www_form`, so a
  # `+` UTC offset reaches the server as `%2B` instead of being read as a space.
  module ReadQuery
    protected

    def list_url(query)
      uri = URI.parse(api_endpoint)
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    def resource_url(id, blank_message, query = {})
      raise Error, blank_message unless id.is_a?(String)

      trimmed = id.strip
      # A blank id resolves to the index route (bare array, not one record); a bare dot segment
      # retargets the request at another path. Neither would 404, so both are rejected here.
      raise Error, blank_message if trimmed.empty? || [".", ".."].include?(trimmed)

      uri = URI.parse("#{api_endpoint}/#{escape_path_segment(trimmed)}")
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    # `until` is a reserved word, so a method taking an `until:` keyword cannot read it by name;
    # callers pass `binding.local_variable_get(:until)`.
    def window_params(since, until_)
      { since: time_param(:since, since), until: time_param(:until, until_) }
    end

    # Accepts Time, DateTime, Date or an ISO8601 String. Strings go through untouched so the server
    # stays the one validator. Raises ArgumentError before any request for anything else.
    def time_param(name, value)
      case value
      when nil, String then value
      when DateTime then utc_iso8601(value.to_time)
      when Time then utc_iso8601(value)
      when Date then value.iso8601
      else
        raise ArgumentError, "#{name} must be a Time, DateTime, Date or ISO8601 String, got #{value.class}"
      end
    end

    private

    # Whole seconds keep the plain form; a fractional instant keeps its microseconds so a window bound
    # is not silently truncated.
    def utc_iso8601(time)
      utc = time.getutc
      utc.subsec.zero? ? utc.iso8601 : utc.iso8601(6)
    end

    # Escapes to RFC 3986 unreserved, so an id carrying `/`, `?` or `#` cannot retarget the request.
    def escape_path_segment(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end
  end
end
