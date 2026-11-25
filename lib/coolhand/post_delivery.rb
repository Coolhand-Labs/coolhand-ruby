# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "errors"
require_relative "log_queue"

module Coolhand
  # The POST half of {ApiService}: the logging writes (logs and feedback). Failures are logged and
  # swallowed (`nil`) so instrumentation can't break the host app, unless the caller opts in with
  # `raise_on_error:`. Sends made from a {LogQueue} worker retry transient failures and report an
  # unrecovered one to {LogQueue}, so `Coolhand.flush` can say the logs were not delivered. Mix into
  # an {ApiService}: it relies on `api_key`, `log`, `apply_headers`, `format_error_body`,
  # `sanitize_payload_for_json` and {ReadRequests#raise_http_error} from there.
  module PostDelivery
    # Retries after the first attempt, and the base of the linear backoff between them.
    LOG_SEND_RETRIES = 2
    RETRY_BACKOFF = 0.5
    # Failures where the log was most likely not stored: the connection never opened, or a proxy or
    # the server turned the request away. A read timeout, a connection reset or a 504 are ambiguous
    # (the server may have stored the log), so they are not retried: a retry could duplicate it.
    RETRYABLE_ERRORS = [Net::OpenTimeout, SocketError, Errno::ECONNREFUSED].freeze
    RETRYABLE_STATUSES = [429, 502, 503].freeze
    MISSING_KEY_MESSAGE = "Request failed: an API key is required"

    protected

    # Returns the parsed response on success. On failure returns nil, or raises {Coolhand::HttpError}
    # (non-2xx) / {Coolhand::Error} (everything else) when `raise_on_error`. `background` marks a
    # send from a queue worker: it is retried and its failure recorded for `Coolhand.flush`.
    def send_request(payload, success_message, raise_on_error: false, background: false)
      return reject_missing_key(raise_on_error) if missing_api_key?

      attempt_send(payload, success_message, raise_on_error: raise_on_error, background: background)
    end

    def reject_missing_key(raise_on_error)
      raise Error, MISSING_KEY_MESSAGE if raise_on_error

      nil
    end

    private

    def attempt_send(payload, success_message, raise_on_error:, background:)
      result = deliver(build_post(payload), background ? LOG_SEND_RETRIES : 0)
    rescue StandardError => e
      fail_send(e, raise_on_error: raise_on_error, background: background)
    else
      announce_success(success_message)
      result
    end

    # Outside the rescue above: a failing log write (a closed stdout) must not turn a delivered
    # request into a failure, nor raise into the host app.
    def announce_success(message)
      log message
    rescue StandardError
      nil
    end

    def build_post(payload)
      uri = URI.parse(@api_endpoint)
      request = Net::HTTP::Post.new(uri.request_uri)
      apply_headers(request, create_request_options(payload))
      # Clean payload and ensure UTF-8 encoding before JSON generation
      request.body = JSON.generate(sanitize_payload_for_json(payload)).force_encoding("UTF-8")
      [uri, request]
    end

    def deliver(built, retries)
      attempts = 0
      begin
        post_once(*built)
      rescue StandardError => e
        attempts += 1
        raise unless attempts <= retries && transient?(e)

        log "⚠️ Request failed (#{e.message}); retrying (#{attempts}/#{retries})"
        sleep(RETRY_BACKOFF * attempts)
        retry
      end
    end

    def post_once(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      # Bound worst-case latency: with async_logging off this call happens inline in
      # the intercepted request's path (otherwise it ties up the background log
      # worker), so a slow/unreachable Coolhand backend must not hang for Ruby's
      # ~60s Net::HTTP defaults (a stalled upload hits write_timeout).
      http.open_timeout = 5
      http.read_timeout = 5
      http.write_timeout = 5

      # This request goes through the same patched Net::HTTP as the host
      # app's real LLM calls. Without this, a base_url/intercept_addresses
      # configuration that also matches Coolhand's own API host would
      # re-intercept this log-shipping call, generating a second log
      # request that itself gets intercepted, and so on — unbounded
      # request amplification.
      response = Coolhand.without_capture { http.request(request) }
      raise_http_error(response, "Coolhand API") unless response.is_a?(Net::HTTPSuccess)

      parse_success_body(response.body)
    end

    # The server already accepted the request, so a blank, non-JSON or `null` 2xx body (a 204, say) is
    # still a delivery: reporting it as a failure would make a retrying caller store it twice.
    def parse_success_body(body)
      JSON.parse(body.to_s, symbolize_names: true) || {}
    rescue JSON::ParserError
      {}
    end

    def transient?(error)
      return RETRYABLE_STATUSES.include?(error.status) if error.is_a?(HttpError)

      RETRYABLE_ERRORS.any? { |klass| error.is_a?(klass) }
    end

    def fail_send(error, raise_on_error:, background:)
      log failure_message(error)
      LogQueue.record_failure if background
      return nil unless raise_on_error

      raise error if error.is_a?(Error)

      raise Error, "Request failed: #{error.message}"
    end

    def failure_message(error)
      return "❌ Request error: #{error.message}" unless error.is_a?(HttpError)

      "❌ Request failed: #{error.status} - #{format_error_body(error.body)}"
    end
  end
end
