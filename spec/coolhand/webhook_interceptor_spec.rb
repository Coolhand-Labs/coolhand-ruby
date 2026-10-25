# frozen_string_literal: true

require "spec_helper"
require "coolhand/webhook_interceptor"
require "shellwords"
require "logger"

RSpec.describe Coolhand::WebhookInterceptor do
  let(:test_class) do
    Class.new do
      include Coolhand::WebhookInterceptor

      attr_reader :head_status
      attr_accessor :request

      def controller_name
        "webhooks"
      end

      def action_name
        "openai"
      end

      def head(status)
        @head_status = status
      end

      def webhook_secret
        "test_secret"
      end
    end
  end

  let(:controller) { test_class.new }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:validator_valid) { true }
  let(:validator_payload) { { "type" => "batch.completed", "data" => { "id" => "batch_1" } }.to_json }
  let(:validator) do
    instance_double(Coolhand::OpenAi::WebhookValidator,
      valid?: validator_valid,
      payload: validator_payload,
      error_message: "signature invalid",
      release_claim!: nil)
  end

  before do
    stub_const("Rails", Class.new)
    allow(Rails).to receive(:logger).and_return(logger)
    controller.request = instance_double("request")
    allow(Coolhand::OpenAi::WebhookValidator).to receive(:new)
      .with(controller.request, "test_secret")
      .and_return(validator)
  end

  describe "#intercept_batch_request" do
    context "when the webhook signature is valid" do
      it "parses the payload and dispatches the event to BatchResultProcessor" do
        processor = instance_double(Coolhand::OpenAi::BatchResultProcessor, call: nil)
        allow(Coolhand::OpenAi::BatchResultProcessor).to receive(:new)
          .with(event_data: { "id" => "batch_1" })
          .and_return(processor)

        controller.intercept_batch_request

        expect(processor).to have_received(:call)
      end

      it "keeps the webhook-id claimed after successful processing" do
        allow(Coolhand::OpenAi::BatchResultProcessor).to receive(:new)
          .and_return(instance_double(Coolhand::OpenAi::BatchResultProcessor, call: nil))

        controller.intercept_batch_request

        expect(validator).not_to have_received(:release_claim!)
      end
    end

    context "when the webhook signature is invalid" do
      let(:validator_valid) { false }

      it "responds unauthorized and never dispatches to BatchResultProcessor" do
        expect(Coolhand::OpenAi::BatchResultProcessor).not_to receive(:new)

        controller.intercept_batch_request

        expect(controller.head_status).to eq(:unauthorized)
      end

      it "does not release any claim" do
        controller.intercept_batch_request

        expect(validator).not_to have_received(:release_claim!)
      end

      it "logs the validator's error message" do
        expect(Rails.logger).to receive(:info).with(a_string_including("signature invalid"))
        controller.intercept_batch_request
      end
    end

    context "when the event type is not one this gem handles" do
      let(:validator_payload) { { "type" => "something.else", "data" => {} }.to_json }

      it "logs and returns without raising" do
        expect(Coolhand::OpenAi::BatchResultProcessor).not_to receive(:new)
        expect(Rails.logger).to receive(:info).with(a_string_including("Unhandled OpenAI webhook event type"))
        expect { controller.intercept_batch_request }.not_to raise_error
      end
    end

    context "when processing the event raises" do
      it "rescues, logs, halts with :unauthorized (fails closed), and does not propagate the error" do
        allow(controller).to receive(:process_event).and_raise(StandardError, "boom")
        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to intercept batch request: boom"))

        expect { controller.intercept_batch_request }.not_to raise_error
        expect(controller.head_status).to eq(:unauthorized)
      end

      it "releases the webhook-id claim so the sender's retry isn't rejected as a replay" do
        allow(controller).to receive(:process_event).and_raise(StandardError, "boom")

        controller.intercept_batch_request

        expect(validator).to have_received(:release_claim!)
      end
    end

    context "when the configured whsec_ secret is not valid base64 (real validator, not a double)" do
      before do
        allow(Coolhand::OpenAi::WebhookValidator).to receive(:new).and_call_original
        allow(controller).to receive(:webhook_secret).and_return("whsec_not*valid*base64!")
        controller.request = double("request", # rubocop:disable RSpec/VerifiedDoubles
          raw_post: validator_payload,
          headers: { "webhook-signature" => "v1,placeholder",
                     "webhook-timestamp" => Time.now.to_i.to_s,
                     "webhook-id" => "wh_1" })
      end

      it "fails closed: halts with :unauthorized, logs, and never dispatches to BatchResultProcessor" do
        expect(Coolhand::OpenAi::BatchResultProcessor).not_to receive(:new)
        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to intercept batch request"))

        expect(controller.intercept_batch_request).to be false
        expect(controller.head_status).to eq(:unauthorized)
      end
    end

    context "when the webhook payload is valid JSON but not an object (e.g. an array or string)" do
      it "rescues, logs, and halts with :unauthorized instead of passing a non-Hash payload downstream" do
        allow(validator).to receive(:payload).and_return('["not", "an", "object"]')

        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to intercept batch request"))
        expect(controller).not_to receive(:process_event)

        expect { controller.intercept_batch_request }.not_to raise_error
        expect(controller.head_status).to eq(:unauthorized)
      end
    end
  end

  describe "#webhook_secret" do
    it "raises NotImplementedError when the including class doesn't override it" do
      bare_class = Class.new { include Coolhand::WebhookInterceptor }
      expect { bare_class.new.webhook_secret }.to raise_error(NotImplementedError, /must implement #webhook_secret/)
    end
  end

  describe "loading this file in isolation" do
    it "defines Coolhand::OpenAi::WebhookValidator and Coolhand::OpenAi::BatchResultProcessor on its own, " \
       "without relying on another file having required them first" do
      lib_path = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(#{lib_path.inspect})
        require "coolhand/webhook_interceptor"
        raise "WebhookValidator not defined" unless defined?(Coolhand::OpenAi::WebhookValidator)
        raise "BatchResultProcessor not defined" unless defined?(Coolhand::OpenAi::BatchResultProcessor)
        puts "ok"
      RUBY

      # Strip bundler env so this genuinely tests $LOAD_PATH in isolation,
      # not an inherited RUBYOPT/BUNDLE_GEMFILE from `bundle exec rspec`.
      output = `env -u RUBYOPT -u RUBYLIB -u BUNDLE_GEMFILE #{RbConfig.ruby.shellescape} -e #{script.shellescape} 2>&1`

      expect(output).to match(/^ok$/)
    end
  end
end
