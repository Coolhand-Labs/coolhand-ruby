# frozen_string_literal: true

RSpec.describe Coolhand::OpenAi::WebhookValidator do
  subject(:validator) { described_class.new(request, webhook_secret) }

  let(:webhook_secret) { "whsec_MzBOMFki+RuS5YQqmN2O85Dj1/sOFHdncBhwXECP+VY=" }
  let(:webhook_secret_key) { "MzBOMFki+RuS5YQqmN2O85Dj1/sOFHdncBhwXECP+VY=" }
  let(:secret_bytes) { Base64.strict_decode64(webhook_secret_key) }
  let(:webhook_id) { "wh_123456" }
  let(:timestamp) { "1234567890" }
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
  let(:logger) { instance_double(logger, info: nil, warn: nil, error: nil) }
  let(:request) do
    headers_hash = {
      "webhook-signature" => signature_header,
      "webhook-timestamp" => timestamp,
      "webhook-id" => webhook_id
    }

    instance_double(hash,
      headers: headers_hash,
      raw_post: payload,
      body: instance_double(IO, read: payload))
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

        instance_double(hash,
          headers: headers_hash,
          raw_post: payload,
          body: instance_double(IO, read: payload))
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

    context "when signature header is missing in production" do
      let(:request) do
        headers_hash = {
          "webhook-timestamp" => timestamp,
          "webhook-id" => webhook_id
        }

        instance_double(hash,
          headers: headers_hash,
          raw_post: payload,
          body: instance_double(IO, read: payload))
      end

      before do
        allow(Rails).to receive(:env).and_return("production")
        allow(Rails.logger).to receive(:error)
      end

      it "returns false and logs an error" do
        message = /Missing OpenAI webhook signature or timestamp headers - rejecting webhook/
        expect(Rails.logger).to receive(:error).with(message)
        expect(validator.valid?).to be false
      end

      it "sets appropriate error message" do
        validator.valid?
        expect(validator.error_message).to include("Missing OpenAI webhook signature or timestamp headers")
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

        instance_double(hash,
          headers: headers_hash,
          raw_post: payload,
          body: instance_double(IO, read: payload))
      end

      it "accepts alternative header names" do
        expect(validator.valid?).to be true
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
end
