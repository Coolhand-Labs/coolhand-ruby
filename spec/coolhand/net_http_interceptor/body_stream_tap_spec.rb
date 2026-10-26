# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Coolhand::NetHttpInterceptor::BodyStreamTap do
  before do
    allow(Coolhand).to receive(:log)
    Coolhand.configuration.max_captured_body_bytes = 10
  end

  it "passes reads through unchanged and records what went by" do
    tap = described_class.new(StringIO.new("hello"))

    expect(tap.read(3)).to eq("hel")
    expect(tap.read(3)).to eq("lo")
    expect(tap.reached_end?).to be false
    expect(tap.read(3)).to be_nil
    expect(tap).to be_reached_end
    expect(tap.body).to eq("hello")
    expect(tap.bytes_seen).to eq(5)
  end

  it "fills a caller-supplied buffer and returns it, as IO#read does" do
    tap = described_class.new(StringIO.new("hello"))
    buffer = +""

    expect(tap.read(5, buffer)).to equal(buffer)
    expect(buffer).to eq("hello")
    expect(tap.body).to eq("hello")
  end

  it "treats a read with no length as reading to the end" do
    tap = described_class.new(StringIO.new("hello"))

    expect(tap.read).to eq("hello")
    expect(tap).to be_reached_end
  end

  it "drops the buffer once the cap is crossed and only counts from then on" do
    tap = described_class.new(StringIO.new("abcdef" * 4))

    4.times { tap.read(6) }

    expect(tap).to be_overflowed
    expect(tap.body).to be_nil
    expect(tap.bytes_seen).to eq(24)
  end

  it "keeps a body of exactly the cap" do
    tap = described_class.new(StringIO.new("0123456789"))
    tap.read

    expect(tap).not_to be_overflowed
    expect(tap.body).to eq("0123456789")
  end

  it "keeps multi-byte content intact across chunk boundaries" do
    Coolhand.configuration.max_captured_body_bytes = 100
    tap = described_class.new(StringIO.new("こんにちは"))
    nil while tap.read(4)

    expect(tap.body).to eq("こんにちは")
    expect(tap.body.encoding).to eq(Encoding::UTF_8)
  end

  it "never holds more than the cap while a long stream goes by" do
    tap = described_class.new(StringIO.new("x" * 1_000))

    held = Array.new(100) { tap.read(10) && tap.body&.bytesize }

    expect(held.compact.max).to be <= 10
    expect(tap).to be_overflowed
  end

  describe "readpartial" do
    it "is offered only when the source has it, so IO.copy_stream picks the right read" do
      reader, writer = IO.pipe
      only_read = Class.new { def read(*) = nil }.new

      expect(described_class.new(reader)).to respond_to(:readpartial)
      expect(described_class.new(only_read)).not_to respond_to(:readpartial)
    ensure
      reader.close
      writer.close
    end

    it "records the bytes and marks EOF when the source raises EOFError" do
      reader, writer = IO.pipe
      writer.write("abc")
      writer.close
      tap = described_class.new(reader)

      expect(tap.readpartial(10)).to eq("abc")
      expect { tap.readpartial(10) }.to raise_error(EOFError)
      expect(tap).to be_reached_end
      expect(tap.body).to eq("abc")
    ensure
      reader.close
    end
  end

  it "does not expose #to_io, which would let IO.copy_stream read around it" do
    expect(described_class.new(StringIO.new("x"))).not_to respond_to(:to_io)
  end

  it "lets the source's own errors through" do
    source = Object.new
    def source.read(*) = raise(IOError, "boom")

    expect { described_class.new(source).read(1) }.to raise_error(IOError, "boom")
  end

  it "never raises into the host when recording fails, and gives up capturing" do
    tap = described_class.new(StringIO.new("hello"))
    allow(Coolhand::NetHttpInterceptor::Helpers).to receive(:over_capture_limit?).and_raise("bad config")

    expect(tap.read(3)).to eq("hel")
    expect(tap.read(3)).to eq("lo")
    expect(tap).to be_failed
    expect(tap.body).to be_nil
    expect(tap).not_to be_overflowed
  end
end
