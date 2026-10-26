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

      private

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

        controller.send(:intercept_batch_request)

        expect(processor).to have_received(:call)
      end

      it "keeps the webhook-id claimed after successful processing" do
        allow(Coolhand::OpenAi::BatchResultProcessor).to receive(:new)
          .and_return(instance_double(Coolhand::OpenAi::BatchResultProcessor, call: nil))

        controller.send(:intercept_batch_request)

        expect(validator).not_to have_received(:release_claim!)
      end
    end

    context "when the webhook signature is invalid" do
      let(:validator_valid) { false }

      it "responds unauthorized and never dispatches to BatchResultProcessor" do
        expect(Coolhand::OpenAi::BatchResultProcessor).not_to receive(:new)

        controller.send(:intercept_batch_request)

        expect(controller.head_status).to eq(:unauthorized)
      end

      it "does not release any claim" do
        controller.send(:intercept_batch_request)

        expect(validator).not_to have_received(:release_claim!)
      end

      it "logs the validator's error message" do
        expect(Rails.logger).to receive(:info).with(a_string_including("signature invalid"))
        controller.send(:intercept_batch_request)
      end
    end

    context "when the event type is not one this gem handles" do
      let(:validator_payload) { { "type" => "something.else", "data" => {} }.to_json }

      it "logs and returns without raising" do
        expect(Coolhand::OpenAi::BatchResultProcessor).not_to receive(:new)
        expect(Rails.logger).to receive(:info).with(a_string_including("Unhandled OpenAI webhook event type"))
        expect { controller.send(:intercept_batch_request) }.not_to raise_error
      end
    end

    context "when processing the event raises" do
      it "rescues, logs, halts with :unauthorized (fails closed), and does not propagate the error" do
        allow(controller).to receive(:process_event).and_raise(StandardError, "boom")
        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to intercept batch request: boom"))

        expect { controller.send(:intercept_batch_request) }.not_to raise_error
        expect(controller.head_status).to eq(:unauthorized)
      end

      it "releases the webhook-id claim so the sender's retry isn't rejected as a replay" do
        allow(controller).to receive(:process_event).and_raise(StandardError, "boom")

        controller.send(:intercept_batch_request)

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

        expect(controller.send(:intercept_batch_request)).to be false
        expect(controller.head_status).to eq(:unauthorized)
      end
    end

    context "when the webhook payload is valid JSON but not an object (e.g. an array or string)" do
      it "rescues, logs, and halts with :unauthorized instead of passing a non-Hash payload downstream" do
        allow(validator).to receive(:payload).and_return('["not", "an", "object"]')

        expect(Rails.logger).to receive(:error).with(a_string_including("Failed to intercept batch request"))
        expect(controller).not_to receive(:process_event)

        expect { controller.send(:intercept_batch_request) }.not_to raise_error
        expect(controller.head_status).to eq(:unauthorized)
      end
    end
  end

  describe "#webhook_secret" do
    it "raises NotImplementedError when the including class doesn't override it" do
      bare_class = Class.new { include Coolhand::WebhookInterceptor }
      expect { bare_class.new.send(:webhook_secret) }
        .to raise_error(NotImplementedError, /must implement #webhook_secret/)
    end

    it "uses a subclass override" do
      expect(controller.send(:webhook_secret)).to eq("test_secret")
    end
  end

  describe "helper method visibility" do
    let(:helpers) { %i[intercept_batch_request webhook_secret process_event] }
    let(:plain_class) { Class.new { include Coolhand::WebhookInterceptor } }

    it "keeps the helpers out of the including class's public methods" do
      expect(plain_class.new.public_methods).not_to include(*helpers)
      expect(plain_class.new.private_methods).to include(*helpers)
    end

    context "when a host controller re-defines the helpers as public" do
      # Stand-in for AbstractController::Base, whose action_methods is every
      # public instance method (the real one returns a Set of strings).
      let(:framework_base) do
        Class.new do
          def self.action_methods
            Set.new(public_instance_methods(false).map(&:to_s))
          end
        end
      end
      let(:host_class) do
        Class.new(framework_base) do
          include Coolhand::WebhookInterceptor

          def openai; end

          def webhook_secret
            "public_secret"
          end

          def process_event(_payload); end
        end
      end

      it "makes the overrides public again, as plain Ruby visibility rules dictate" do
        expect(host_class.new.public_methods).to include(:webhook_secret, :process_event)
      end

      it "still excludes every helper from action_methods so none is routable" do
        expect(host_class.action_methods).to contain_exactly("openai")
      end

      it "applies to subclasses of the host controller" do
        subclass = Class.new(host_class) { def other; end }
        expect(subclass.action_methods).not_to include(*helpers.map(&:to_s))
      end

      it "still honours the public override when the interceptor calls it" do
        host = host_class.new
        allow(Coolhand::OpenAi::WebhookValidator).to receive(:new).with(anything, "public_secret").and_return(validator)
        allow(host).to receive_messages(head: nil, controller_name: "w", action_name: "a", request: double)
        host.send(:intercept_batch_request)
        expect(Coolhand::OpenAi::WebhookValidator).to have_received(:new).with(anything, "public_secret")
      end
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
