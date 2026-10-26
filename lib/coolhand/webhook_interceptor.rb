# frozen_string_literal: true

require_relative "open_ai/webhook_validator"
require_relative "open_ai/batch_result_processor"

module Coolhand
  module WebhookInterceptor
    # Helpers that must never be routable as controller actions.
    HELPER_METHODS = %w[intercept_batch_request webhook_secret process_event].freeze
    private_constant :HELPER_METHODS

    # `private` below only covers the definitions in this module. A host that
    # re-defines `webhook_secret` or `process_event` as public would make them
    # public again, and Rails would then count them as action methods. Filtering
    # them out of `action_methods` keeps them unroutable either way, without this
    # gem depending on Rails (`super` is Rails' own `action_methods`).
    module ClassMethods
      def action_methods
        super - HELPER_METHODS
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    private

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
      # Give the webhook-id back so the sender's retry isn't rejected as a replay.
      @validator&.release_claim!
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
