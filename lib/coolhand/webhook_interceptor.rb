# frozen_string_literal: true

require_relative "open_ai/webhook_validator"
require_relative "open_ai/batch_result_processor"

module Coolhand
  module WebhookInterceptor
    def intercept_batch_request
      Rails.logger.info("[Interceptor] #{controller_name}##{action_name}")

      @validator = Coolhand::OpenAi::WebhookValidator.new(request, webhook_secret)

      unless @validator.valid?
        Rails.logger.info("[Interceptor] Webhook validated failed: #{@validator.error_message}")
        head :unauthorized
        return false
      end

      payload = JSON.parse(@validator.payload)
      raise TypeError, "webhook payload must be a JSON object, got #{payload.class}" unless payload.is_a?(Hash)

      process_event(payload)
    rescue StandardError => e
      # Fail closed: any error here (malformed payload, a bug in
      # process_event/BatchResultProcessor, etc.) must still halt the
      # before_action chain. Falling through without calling `head` would
      # let the controller action run for a request whose webhook
      # signature was never confirmed valid.
      Rails.logger.error("[Interceptor] Failed to intercept batch request: #{e.message}")
      head :unauthorized
      false
    end

    def webhook_secret
      raise NotImplementedError, "#{self.class} must implement #webhook_secret"
    end

    def process_event(payload)
      event_type = payload["type"]
      event_data = payload["data"]

      case event_type
      when "batch.completed", "batch.failed", "batch.expired", "batch.cancelled"
        Coolhand::OpenAi::BatchResultProcessor.new(event_data: event_data).call
      else
        Rails.logger.info("[Interceptor] Unhandled OpenAI webhook event type: #{event_type}")
      end
    end
  end
end
