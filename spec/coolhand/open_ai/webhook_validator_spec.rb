# frozen_string_literal: true

require "spec_helper"
require "coolhand/open_ai/webhook_validator"

RSpec.describe Coolhand::OpenAi::WebhookValidator do
  subject(:validator) { described_class.new(request, webhook_secret) }

  let(:webhook_secret) { "whsec_MzBOMFki+RuS5YQqmN2O85Dj1/sOFHdncBhwXECP+VY=" }
  let(:webhook_secret_key) { "MzBOMFki+RuS5YQqmN2O85Dj1/sOFHdncBhwXECP+VY=" }
  let(:secret_bytes) { Base64.strict_decode64(webhook_secret_key) }
  let(:webhook_id) { "wh_123456" }
  let(:timestamp) { Time.now.to_i.to_s }
  let(:payload) { { type: "batch.completed", data: { id: "batch_123", status: "completed" } }.to_json }
  let(:signed_payload) { "#{webhook_id}.#{timestamp}.#{payload}" }
  let(:valid_signature) do
    Base64.strict_encode64(
      OpenSSL::HMAC.digest(
        OpenSSL::Digest.new("sha256"),
        secret_bytes,
        signed_payload
      )
    )
  end
  let(:signature_header) { "v1,#{valid_signature}" }
  let(:logger) { instance_double("logger", info: nil, warn: nil, error: nil) }
  let(:request) do
    headers_hash = {
      "webhook-signature" => signature_header,
      "webhook-timestamp" => timestamp,
      "webhook-id" => webhook_id
    }

    instance_double("hash",
      headers: headers_hash,
      raw_post: payload,
      body: instance_double("IO", read: payload))
  end

  before do
    stub_const("Rails", Class.new)
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe "#valid?" do
    context "when signature is valid" do
      it "returns true" do
        expect(validator.valid?).to be true
      end

      it "stores the payload" do
        validator.valid?
        expect(validator.payload).to eq(payload)
      end

      it "clears errors" do
        validator.valid?
        expect(validator.errors).to be_empty
      end
    end

    context "when payload is empty in production" do
      let(:payload) { nil }
      let(:request) do
        headers_hash = {
          "webhook-signature" => signature_header,
          "webhook-timestamp" => timestamp,
          "webhook-id" => webhook_id
        }

        instance_double("hash",
          headers: headers_hash,
          raw_post: payload,
          body: instance_double("IO", read: payload))
      end

      before do
        allow(Rails).to receive(:env).and_return("production")
        allow(Rails.logger).to receive(:error)
      end

      it "returns false and logs an error" do
        expect(Rails.logger).to receive(:error).with(/Empty webhook payload - rejecting webhook/)
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("Empty webhook payload")
      end
    end

    context "when webhook secret is not configured in production" do
      let(:webhook_secret) { nil }

      before do
        allow(Rails).to receive(:env).and_return("production")
        allow(Rails.logger).to receive(:error)
      end

      it "returns false and logs an error" do
        expect(Rails.logger).to receive(:error).with(/not configured - rejecting webhook/)
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("not configured - rejecting webhook")
      end
    end

    context "when webhook secret is a blank string in production" do
      let(:webhook_secret) { "   " }

      before do
        allow(Rails).to receive(:env).and_return("production")
        allow(Rails.logger).to receive(:error)
      end

      it "is treated the same as an unconfigured secret and rejected, rather than used as the HMAC key" do
        expect(Rails.logger).to receive(:error).with(/not configured - rejecting webhook/)
        expect(validator.valid?).to be false
      end
    end

    context "when signature header is missing in production" do
      let(:request) do
        headers_hash = {
          "webhook-timestamp" => timestamp,
          "webhook-id" => webhook_id
        }

        instance_double("hash",
          headers: headers_hash,
          raw_post: payload,
          body: instance_double("IO", read: payload))
      end

      before do
        allow(Rails).to receive(:env).and_return("production")
        allow(Rails.logger).to receive(:error)
      end

      it "returns false and logs an error" do
        message = /Missing OpenAI webhook signature, timestamp, or id headers - rejecting webhook/
        expect(Rails.logger).to receive(:error).with(message)
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("Missing OpenAI webhook signature, timestamp, or id headers")
      end
    end

    context "when webhook id header is missing in production" do
      let(:request) do
        headers_hash = {
          "webhook-signature" => signature_header,
          "webhook-timestamp" => timestamp
        }

        instance_double("hash",
          headers: headers_hash,
          raw_post: payload,
          body: instance_double("IO", read: payload))
      end

      before do
        allow(Rails).to receive(:env).and_return("production")
        allow(Rails.logger).to receive(:error)
      end

      it "returns false rather than treating a nil id as a valid, dedupable webhook id" do
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("Missing OpenAI webhook signature, timestamp, or id headers")
      end
    end

    context "when signature header format is invalid" do
      let(:signature_header) { "invalid_format" }

      it "returns false" do
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("OpenAI webhook signature verification failed")
      end
    end

    context "when signature is invalid" do
      let(:signature_header) { "v1,invalid_signature" }

      it "returns false" do
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("OpenAI webhook signature verification failed")
      end
    end

    context "when the header carries multiple space-separated signatures (secret rotation)" do
      context "when the valid signature is second" do
        let(:signature_header) { "v1,bogus v1,#{valid_signature}" }

        it "returns true" do
          expect(validator.valid?).to be true
        end
      end

      context "when the valid signature is first" do
        let(:signature_header) { "v1,#{valid_signature} v1,bogus" }

        it "returns true" do
          expect(validator.valid?).to be true
        end
      end

      context "when no signature is valid" do
        let(:signature_header) { "v1,bogus1 v1,bogus2" }

        it "returns false" do
          expect(validator.valid?).to be false
          expect(validator.error_message).to include("OpenAI webhook signature verification failed")
        end
      end

      context "when the valid signature is under a different version" do
        let(:signature_header) { "v1,bogus v2,#{valid_signature}" }

        it "ignores non-v1 entries and returns false" do
          expect(validator.valid?).to be false
        end
      end

      context "when the timestamp is stale" do
        let(:timestamp) { (Time.now.to_i - 301).to_s }
        let(:signature_header) { "v1,bogus v1,#{valid_signature}" }

        it "still rejects after a signature match" do
          expect(validator.valid?).to be false
          expect(validator.error_message).to include("timestamp outside replay-protection tolerance window")
        end
      end

      context "when the webhook id is replayed" do
        let(:signature_header) { "v1,bogus v1,#{valid_signature}" }

        it "rejects the replay" do
          expect(validator.valid?).to be true
          replay = described_class.new(request, webhook_secret)
          expect(replay.valid?).to be false
          expect(replay.error_message).to include("already processed")
        end
      end

      context "when an entry is a bare v1, with an empty signature" do
        let(:signature_header) { "v1, v1,#{valid_signature}" }

        it "does not match the empty entry but still accepts the valid one" do
          expect(validator.valid?).to be true
        end
      end

      context "when the only entry is a bare v1," do
        let(:signature_header) { "v1," }

        it "returns false" do
          expect(validator.valid?).to be false
        end
      end

      context "when entries are separated by irregular whitespace" do
        let(:signature_header) { " v1,bogus \t  v1,#{valid_signature} " }

        it "returns true" do
          expect(validator.valid?).to be true
        end
      end

      context "when the header is not valid UTF-8" do
        let(:signature_header) { (+"v1,\xFF").force_encoding("UTF-8") }

        it "returns false instead of raising" do
          expect(validator.valid?).to be false
        end
      end

      context "when one entry is not valid UTF-8 but another is valid" do
        let(:signature_header) { "v1,\xFF v1,#{valid_signature}".force_encoding("UTF-8") }

        it "returns true" do
          expect(validator.valid?).to be true
        end
      end

      context "when no entry is v1" do
        let(:signature_header) { "v2,bogus" }

        it "returns false" do
          expect(validator.valid?).to be false
        end
      end

      context "when the secret is a bare whsec_ (empty key)" do
        let(:webhook_secret) { "whsec_" }
        let(:secret_bytes) { "" }
        let(:signature_header) { "v1,bogus v1,#{valid_signature}" }

        it "rejects even a signature made with the empty key" do
          expect(validator.valid?).to be false
        end
      end
    end

    context "with whsec_ prefixed secret" do
      let(:webhook_secret) { "whsec_MzBOMFki+RuS5YQqmN2O85Dj1/sOFHdncBhwXECP+VY=" }

      it "extracts and decodes the secret correctly" do
        expect(validator.valid?).to be true
      end
    end

    context "with raw secret (backward compatibility)" do
      let(:webhook_secret) { "raw_secret_bytes" }
      let(:secret_bytes) { webhook_secret }
      let(:signed_payload) { "#{webhook_id}.#{timestamp}.#{payload}" }
      let(:valid_signature) do
        Base64.strict_encode64(
          OpenSSL::HMAC.digest(
            OpenSSL::Digest.new("sha256"),
            secret_bytes,
            signed_payload
          )
        )
      end

      it "uses raw secret directly when no whsec_ prefix" do
        expect(validator.valid?).to be true
      end
    end

    context "when webhook headers use alternative names" do
      let(:request) do
        headers_hash = {
          "openai-signature" => signature_header,
          "openai-timestamp" => timestamp,
          "openai-id" => webhook_id
        }

        instance_double("hash",
          headers: headers_hash,
          raw_post: payload,
          body: instance_double("IO", read: payload))
      end

      it "accepts alternative header names" do
        expect(validator.valid?).to be true
      end
    end

    context "when Rails.env is in the development/test allowlist (permissive fallback path)" do
      before do
        allow(Rails).to receive(:env).and_return("development")
        allow(Rails.logger).to receive(:warn)
      end

      context "when the webhook secret is not configured" do
        let(:webhook_secret) { nil }

        it "allows the webhook through and warns instead of rejecting" do
          expect(Rails.logger).to receive(:warn).with(/skipping signature verification in development/)
          expect(validator.valid?).to be true
        end
      end

      context "when Rails.env is \"test\"" do
        let(:webhook_secret) { nil }

        before { allow(Rails).to receive(:env).and_return("test") }

        it "also allows the webhook through and warns instead of rejecting" do
          expect(Rails.logger).to receive(:warn).with(/skipping signature verification in test/)
          expect(validator.valid?).to be true
        end
      end

      context "when the payload is empty" do
        let(:payload) { nil }
        let(:request) do
          headers_hash = {
            "webhook-signature" => signature_header,
            "webhook-timestamp" => timestamp,
            "webhook-id" => webhook_id
          }

          instance_double("hash",
            headers: headers_hash,
            raw_post: payload,
            body: instance_double("IO", read: payload))
        end

        it "allows the webhook through and warns instead of rejecting" do
          expect(Rails.logger).to receive(:warn).with(/allowing in development environment/)
          expect(validator.valid?).to be true
        end
      end
    end

    context "when a secret is configured and Rails.env is development or test (unsigned requests must be rejected)" do
      def request_with(headers_hash)
        instance_double("hash",
          headers: headers_hash,
          raw_post: payload,
          body: instance_double("IO", read: payload))
      end

      let(:full_headers) do
        { "webhook-signature" => signature_header, "webhook-timestamp" => timestamp, "webhook-id" => webhook_id }
      end

      before { allow(Rails.logger).to receive(:error) }

      %w[development test].each do |env_name|
        context "when Rails.env is #{env_name.inspect}" do
          before { allow(Rails).to receive(:env).and_return(env_name) }

          it "rejects a request with no signature headers at all" do
            request = request_with({})
            validator = described_class.new(request, webhook_secret)

            expect(Rails.logger).to receive(:error).with(/Missing OpenAI webhook signature, timestamp, or id headers/)
            expect(validator.valid?).to be false
            expect(validator.error_message).to eq(
              "Missing OpenAI webhook signature, timestamp, or id headers - rejecting webhook"
            )
          end

          full_headers_keys = %w[webhook-signature webhook-timestamp webhook-id]
          full_headers_keys.each do |missing|
            it "rejects a partially present header set missing #{missing}" do
              request = request_with(full_headers.except(missing))
              validator = described_class.new(request, webhook_secret)

              expect(validator.valid?).to be false
              expect(validator.error_message).to match(/Missing OpenAI webhook signature, timestamp, or id headers/)
            end
          end

          it "still accepts a correctly signed request" do
            expect(described_class.new(request_with(full_headers), webhook_secret).valid?).to be true
          end
        end
      end
    end

    context "when Rails.env is an unrecognized or unset name (must default to strict)" do
      let(:webhook_secret) { nil }

      before { allow(Rails.logger).to receive(:error) }

      %w[prod production-eu review staging production].each do |env_name|
        context "when Rails.env is #{env_name.inspect}" do
          before { allow(Rails).to receive(:env).and_return(env_name) }

          it "rejects the webhook instead of falling back to the permissive path" do
            expect(Rails.logger).to receive(:error).with(/not configured - rejecting webhook/)
            expect(validator.valid?).to be false
          end
        end
      end

      context "when Rails.env is nil (unset)" do
        before { allow(Rails).to receive(:env).and_return(nil) }

        it "rejects the webhook instead of falling back to the permissive path" do
          expect(Rails.logger).to receive(:error).with(/not configured - rejecting webhook/)
          expect(validator.valid?).to be false
        end
      end
    end

    context "when replay protection checks apply" do
      context "when the timestamp is older than the tolerance window" do
        let(:timestamp) { (Time.now.to_i - 301).to_s }

        it "returns false" do
          expect(validator.valid?).to be false
        end

        it "sets appropriate error message" do
          validator.valid?
          expect(validator.error_message).to include("timestamp outside replay-protection tolerance window")
        end
      end

      context "when the timestamp is further in the future than the tolerance window" do
        let(:timestamp) { (Time.now.to_i + 301).to_s }

        it "returns false" do
          expect(validator.valid?).to be false
        end
      end

      context "when a custom tolerance is configured" do
        let(:timestamp) { (Time.now.to_i - 301).to_s }

        before { Coolhand.configuration.webhook_replay_tolerance_seconds = 600 }

        it "honors the wider window" do
          expect(validator.valid?).to be true
        end
      end

      context "when the same webhook id is replayed" do
        it "accepts the first request and rejects the replay" do
          expect(validator.valid?).to be true

          replay = described_class.new(request, webhook_secret)
          expect(replay.valid?).to be false
          expect(replay.error_message).to include("already processed")
        end
      end

      context "when two requests use different webhook ids" do
        it "does not treat the second as a replay of the first" do
          expect(validator.valid?).to be true

          other_id = "wh_654321"
          other_signed_payload = "#{other_id}.#{timestamp}.#{payload}"
          other_signature = Base64.strict_encode64(
            OpenSSL::HMAC.digest(OpenSSL::Digest.new("sha256"), secret_bytes, other_signed_payload)
          )
          other_headers = {
            "webhook-signature" => "v1,#{other_signature}",
            "webhook-timestamp" => timestamp,
            "webhook-id" => other_id
          }
          other_request = instance_double("hash",
            headers: other_headers,
            raw_post: payload,
            body: instance_double("IO", read: payload))

          expect(described_class.new(other_request, webhook_secret).valid?).to be true
        end
      end
    end
  end

  describe "#error_message" do
    context "when there are no errors" do
      it "returns empty string" do
        validator.valid?
        expect(validator.error_message).to eq("")
      end
    end

    context "when there are errors" do
      let(:signature_header) { "invalid_format" }

      it "returns joined error messages" do
        validator.valid?
        expect(validator.error_message).to eq("OpenAI webhook signature verification failed")
      end
    end
  end

  describe "#payload" do
    context "when validation has not been run" do
      it "returns nil" do
        expect(validator.payload).to be_nil
      end
    end

    context "when validation succeeds" do
      it "returns the payload" do
        validator.valid?
        expect(validator.payload).to eq(payload)
      end
    end

    context "when validation fails" do
      let(:signature_header) { "v1,invalid_signature" }

      it "still has the payload (read at beginning of validation)" do
        validator.valid?
        expect(validator.payload).to eq(payload)
      end
    end
  end

  describe "#valid? with a degenerate secret" do
    let(:webhook_secret) { "whsec_" }
    let(:secret_bytes) { "" }

    it "rejects a request signed with the empty key a bare whsec_ secret decodes to" do
      expect(validator.valid?).to be false
      expect(validator.errors).not_to be_empty
    end
  end
end
