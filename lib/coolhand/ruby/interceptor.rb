# frozen_string_literal: true

module Coolhand
  # This module contains the logic for monkey-patching Net::HTTP
  # to intercept outgoing requests.
  module Interceptor
    # Class variable to ensure we only patch once.
    @patched = false

    def self.patch!
      return if @patched

      Coolhand.log '🔍 Setting up Coolhand monitoring for Net::HTTP...'

      # Re-open the Net::HTTP class to add our interception logic.
      Net::HTTP.class_eval do
        # Alias the original 'request' method so we can call it later.
        alias_method :original_request, :request

        # Redefine the 'request' method.
        def request(req, body = nil, &block)
          # Check if the request is destined for OpenAI or our own logging endpoint.
          # We must not intercept calls to our own logger, or we'll cause an infinite loop.
          is_openai_call = address.include?('openai.com')
          is_coolhand_logging_call = address.include?('coolhand.io') || address.include?('localhost:3000')

          # If it's not an OpenAI call, just use the original method.
          return original_request(req, body, &block) unless is_openai_call && !is_coolhand_logging_call

          Coolhand.log "🎯 INTERCEPTING OpenAI call to #{address}"

          Stats.increment_intercepted_calls

          start_time = Time.now

          # Execute the original request to get the response
          response = original_request(req, body, &block)

          end_time = Time.now

          # Gather all the data into a hash
          call_data = {
            id: Stats.intercepted_calls,
            timestamp: start_time.utc.iso8601,
            url: "#{use_ssl? ? 'https' : 'http'}://#{address}#{req.path}",
            method: req.method,
            request_headers: LogFormatter.sanitize_headers(req.to_hash),
            request_body: LogFormatter.parse_json(body || req.body),
            status_code: response.code.to_i,
            response_headers: LogFormatter.sanitize_headers(response.to_hash),
            response_body: LogFormatter.parse_json(response.body),
            duration_ms: ((end_time - start_time) * 1000).round,
            protocol: 'net/http'
          }

          # Log the collected data to the Coolhand API in a non-blocking thread.
          Thread.new { Logger.log_to_api(call_data) }

          # Return the original response to the caller, so the app continues to work.
          response
        end
      end

      @patched = true
      Coolhand.log '📡 Monitoring all outbound Net::HTTP requests...'
    end
  end
end