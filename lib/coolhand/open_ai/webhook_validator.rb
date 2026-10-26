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
        @claimed_id = nil
        @payload = request.raw_post || request.body.read

        return false unless payload_valid?
        return validate_in_non_production_env unless Coolhand.required_field?(webhook_secret)

        secret_bytes = extract_secret_bytes
        webhook_signature, webhook_timestamp, webhook_id = extract_webhook_headers

        unless webhook_signature && webhook_timestamp && webhook_id
          return reject_unsigned("Missing OpenAI webhook signature, timestamp, or id headers")
        end

        verify_signature(webhook_signature, webhook_timestamp, webhook_id, secret_bytes)
      end

      def error_message
        @errors.join(", ")
      end

      # Gives back the webhook-id claim made by the last successful `valid?` so a same-id retry
      # (e.g. after processing failed) isn't rejected as a replay. A no-op when nothing was claimed
      # or when the store has no `release!` (custom stores may implement only `claim!`).
      def release_claim!
        claimed_id = @claimed_id
        return unless claimed_id

        @claimed_id = nil
        id_store.release!(claimed_id) if id_store.respond_to?(:release!)
      rescue StandardError => e
        # Best effort: a failing store must not stop the caller from rejecting the request.
        Rails.logger.error("OpenAI webhook id release failed: #{e.message}")
      end

      private

      attr_reader :webhook_secret

      # Only a nil payload counts as missing. An empty string is a real (empty) body, so it continues
      # to the signature check, where it is accepted only if it was actually signed.
      def payload_valid?
        return true if @payload
        return reject_unsigned("Empty webhook payload") if Coolhand.required_field?(webhook_secret)

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
          reject("#{problem} - rejecting webhook (Rails.env=#{Rails.env.inspect} " \
                 "not in development/test allowlist)")
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

      # A secret is configured, so anything that can't be verified is rejected in every environment.
      def reject_unsigned(problem)
        reject("#{problem} - rejecting webhook")
      end

      def reject(message)
        @errors << message
        Rails.logger.error(message)
        false
      end

      def verify_signature(webhook_signature, webhook_timestamp, webhook_id, secret_bytes)
        signed_payload = "#{webhook_id}.#{webhook_timestamp}.#{@payload}"
        expected_signature = calculate_expected_signature(secret_bytes, signed_payload)

        # An empty key (a bare "whsec_" secret) makes the HMAC forgeable by anyone, so never accept it.
        signature_valid = !secret_bytes.empty? && signature_matches?(webhook_signature, expected_signature)

        return reject("OpenAI webhook signature verification failed") unless signature_valid

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

        reject("OpenAI webhook timestamp outside replay-protection tolerance window")
      end

      # The timestamp check accepts anything within +/- tolerance of now, so a request stamped
      # `now + tolerance` stays fresh until `now + 2 * tolerance`. Remember the id for twice the
      # tolerance so it can't be replayed after its claim expires but while it is still fresh.
      def webhook_id_unused?(webhook_id)
        ttl = Coolhand.configuration.webhook_replay_tolerance_seconds * 2
        if id_store.claim!(webhook_id, ttl)
          @claimed_id = webhook_id
          return true
        end

        reject("OpenAI webhook id already processed (replay protection)")
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
