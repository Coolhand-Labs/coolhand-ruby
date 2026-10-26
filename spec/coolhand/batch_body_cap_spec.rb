# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::BatchBodyCap do
  before { Coolhand.configuration.max_captured_body_bytes = 50 }

  it "returns a body within the cap untouched" do
    body = { "a" => "b" }

    expect(described_class.cap(body)).to equal(body)
  end

  it "replaces a body over the cap with the body_too_large marker, sized by its JSON" do
    body = { "text" => "x" * 100 }

    expect(described_class.cap(body)).to eq(
      "_coolhand_capture_skipped" => "body_too_large", "size_bytes" => body.to_json.bytesize, "max_bytes" => 50
    )
  end

  it "uses the same marker shape as the Net::HTTP path" do
    body = { "text" => "x" * 100 }
    via_http_path = Coolhand::NetHttpInterceptor::Helpers.cap_and_parse(body.to_json, nil)

    expect(described_class.cap(body)).to eq(via_http_path)
  end

  it "counts bytes, not characters" do
    body = { "t" => "こんにちは" * 4 }

    expect(described_class.cap(body)["size_bytes"]).to eq(body.to_json.bytesize)
  end

  it "passes nil through" do
    expect(described_class.cap(nil)).to be_nil
  end

  it "skips serializing when the source JSON is small enough to be within the cap even after growth" do
    body = { "a" => "b" }
    allow(JSON).to receive(:generate).and_call_original

    expect(described_class.cap(body, source_size: 10)).to equal(body)
    expect(JSON).not_to have_received(:generate)
  end

  it "still measures the body when the source size could re-serialize to more than the cap" do
    expect(described_class.cap({ "a" => "b" }, source_size: 11)).to eq({ "a" => "b" })
    expect(described_class.cap({ "text" => "x" * 100 }, source_size: 120)["_coolhand_capture_skipped"])
      .to eq("body_too_large")
  end

  it "replaces a body that cannot be serialized with a marker instead of raising" do
    expect(described_class.cap({ "n" => Float::INFINITY })).to eq("_coolhand_capture_skipped" => "unserializable_body")
    deep = (1..150).reduce("x") { |inner, _| [inner] }
    expect(described_class.cap(deep)).to eq("_coolhand_capture_skipped" => "nesting_too_deep")
  end

  it "does not let a short exponent float in the source hide an over-cap body" do
    source = "[#{Array.new(12, '1e9').join(',')}]"
    body = JSON.parse(source)

    expect(source.bytesize).to be <= 50
    expect(described_class.cap(body, source_size: source.bytesize)["_coolhand_capture_skipped"])
      .to eq("body_too_large")
  end

  it "leaves every body alone when the cap is disabled" do
    Coolhand.configuration.max_captured_body_bytes = nil
    body = { "text" => "x" * 100 }
    allow(JSON).to receive(:generate).and_call_original

    expect(described_class.cap(body)).to equal(body)
    expect(JSON).not_to have_received(:generate)
  end
end
