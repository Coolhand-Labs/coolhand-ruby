# frozen_string_literal: true

require "openssl"

require_relative "webhook_id_store"

module Coolhand
  module OpenAi
    class WebhookValidator
      SIGNATURE_VERSION_PREFIX = "v1,"
      private_constant :SIGNATURE_VERSION_PREFIX

      attr_reader :request, :errors, :payload

      def initialize(request, webhook_secret)
        @request = request
        @errors = []
        @webhook_secret = webhook_secret
      end

      def valid?
        @errors.clear
        @payload = request.raw_post || request.body.read

        return false unless payload_valid?
        return validate_in_non_production_env unless Coolhand.required_field?(webhook_secret)

        secret_bytes = extract_secret_bytes
        webhook_signature, webhook_timestamp, webhook_id = extract_webhook_headers

        return validate_headers_in_non_production_env unless webhook_signature && webhook_timestamp && webhook_id

        verify_signature(webhook_signature, webhook_timestamp, webhook_id, secret_bytes)
      end

      def error_message
        @errors.join(", ")
      end

      private

      attr_reader :webhook_secret

      def payload_valid?
        return true if @payload

        enforce_or_allow("Empty webhook payload",
          "Empty webhook payload - allowing in #{Rails.env} environment")
      end

      def validate_in_non_production_env
        enforce_or_allow("OpenAI webhook secret not configured",
          "Webhook Secret is not configured - skipping signature verification in #{Rails.env}")
      end

      # Outside the development/test allowlist the webhook is rejected with `problem`; inside it the
      # check is skipped with a warning.
      def enforce_or_allow(problem, allow_warning)
        if should_enforce_strict_validation?
          @errors << "#{problem} - rejecting webhook (Rails.env=#{Rails.env.inspect} " \
                     "not in development/test allowlist)"
          Rails.logger.error(@errors.last)
          false
        else
          Rails.logger.warn(allow_warning)
          true
        end
      end

      def extract_secret_bytes
        if @webhook_secret.start_with?("whsec_")
          webhook_secret_key = @webhook_secret[6..]
          Base64.strict_decode64(webhook_secret_key)
        else
          @webhook_secret
        end
      end

      def extract_webhook_headers
        webhook_signature = request.headers["webhook-signature"] || request.headers["openai-signature"]
        webhook_timestamp = request.headers["webhook-timestamp"] || request.headers["openai-timestamp"]
        webhook_id = request.headers["webhook-id"] || request.headers["openai-id"]
        [webhook_signature, webhook_timestamp, webhook_id]
      end

      def validate_headers_in_non_production_env
        if should_enforce_strict_validation?
          @errors << "Missing OpenAI webhook signature, timestamp, or id headers - " \
                     "rejecting webhook (Rails.env=#{Rails.env.inspect} not in development/test allowlist)"
          Rails.logger.error(@errors.last)
          false
        else
          Rails.logger.warn("Missing OpenAI webhook headers - skipping verification in #{Rails.env}")
          true
        end
      end

      def verify_signature(webhook_signature, webhook_timestamp, webhook_id, secret_bytes)
        signed_payload = "#{webhook_id}.#{webhook_timestamp}.#{@payload}"
        expected_signature = calculate_expected_signature(secret_bytes, signed_payload)

        # An empty key (a bare "whsec_" secret) makes the HMAC forgeable by anyone, so never accept it.
        signature_valid = !secret_bytes.empty? && signature_matches?(webhook_signature, expected_signature)

        unless signature_valid
          @errors << "OpenAI webhook signature verification failed"
          Rails.logger.error(@errors.last)
          return false
        end

        return false unless timestamp_fresh?(webhook_timestamp)
        return false unless webhook_id_unused?(webhook_id)

        true
      end

      # Standard Webhooks allows several space-separated signatures (e.g. during secret rotation);
      # accept the request if any v1 entry matches. Every candidate is compared (`map`, not an
      # `any?` block) so there is no early exit on the first match.
      # Split as binary so a header that isn't valid UTF-8 is rejected rather than raising.
      def signature_matches?(webhook_signature, expected_signature)
        candidates = webhook_signature.b.split.select { |entry| entry.start_with?(SIGNATURE_VERSION_PREFIX) }
        results = candidates.map do |entry|
          secure_compare(entry.delete_prefix(SIGNATURE_VERSION_PREFIX), expected_signature)
        end
        results.any?
      end

      # Checked only after the signature is confirmed valid, so an
      # unsigned/forged request can't poison the id-dedup store (or fail a
      # freshness check) and DoS a later legitimate webhook with the same id.
      def timestamp_fresh?(webhook_timestamp)
        tolerance = Coolhand.configuration.webhook_replay_tolerance_seconds
        age = (Time.now.to_i - webhook_timestamp.to_i).abs
        return true if age <= tolerance

        @errors << "OpenAI webhook timestamp outside replay-protection tolerance window"
        Rails.logger.error(@errors.last)
        false
      end

      def webhook_id_unused?(webhook_id)
        tolerance = Coolhand.configuration.webhook_replay_tolerance_seconds
        return true if id_store.claim!(webhook_id, tolerance)

        @errors << "OpenAI webhook id already processed (replay protection)"
        Rails.logger.error(@errors.last)
        false
      end

      def id_store
        Coolhand.configuration.webhook_id_store
      end

      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        result = 0
        a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
        result.zero?
      end

      def calculate_expected_signature(secret_bytes, signed_payload)
        Base64.strict_encode64(
          OpenSSL::HMAC.digest(
            OpenSSL::Digest.new("sha256"),
            secret_bytes,
            signed_payload
          )
        )
      end

      def should_enforce_strict_validation?
        !%w[development test].include?(Rails.env)
      end
    end
  end
end
