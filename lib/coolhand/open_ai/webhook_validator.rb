# frozen_string_literal: true

module Coolhand
  module OpenAi
    class WebhookValidator
      attr_reader :request, :errors, :payload

      def initialize(request)
        @request = request
        @errors = []
      end

      def valid?
        @errors.clear
        @payload = request.raw_post || request.body.read

        return false unless payload_valid?
        return validate_in_non_production_env unless webhook_secret_configured?

        secret_bytes = extract_secret_bytes
        webhook_signature, webhook_timestamp, webhook_id = extract_webhook_headers

        return validate_headers_in_non_production_env unless webhook_signature && webhook_timestamp

        verify_signature(webhook_signature, webhook_timestamp, webhook_id, secret_bytes)
      end

      def error_message
        @errors.join(", ")
      end

      private

      def payload_valid?
        return true if @payload.present?

        if should_enforce_strict_validation?
          @errors << "Empty webhook payload - rejecting webhook in production/staging"
          Rails.logger.error(@errors.last)
          false
        else
          Rails.logger.warn("Empty webhook payload - allowing in #{Rails.env} environment")
          true
        end
      end

      def webhook_secret_configured?
        webhook_secret = Rails.application.credentials.dig(:ai_api_clients, :openai_webhook)
        @webhook_secret = webhook_secret
        webhook_secret.present?
      end

      def validate_in_non_production_env
        if should_enforce_strict_validation?
          @errors << "OpenAI webhook secret not configured - rejecting webhook in production/staging"
          Rails.logger.error(@errors.last)
          false
        else
          Rails.logger.warn(
            "Rails.application.credentials.ai_api_clients.openai_webhook not configured - " \
              "skipping signature verification in #{Rails.env}"
          )
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
          @errors << "Missing OpenAI webhook signature or timestamp headers - " \
            "rejecting webhook in production/staging"
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

        signature_valid = webhook_signature.start_with?("v1,") &&
          ActiveSupport::SecurityUtils.secure_compare(
            webhook_signature[3..],
            expected_signature
          )

        if signature_valid
          true
        else
          @errors << "OpenAI webhook signature verification failed"
          Rails.logger.error(@errors.last)
          false
        end
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
        Rails.env.production? || Rails.env.staging?
      end
    end
  end
end
