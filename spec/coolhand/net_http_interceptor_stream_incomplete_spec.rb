# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"
require "socket"

# Abandoned streamed responses over a real socket (WebMock's stubbed responses bypass the prepended
# ResponseInterceptor). The server sends the body as separate HTTP chunks so the host's read_body
# block really is called once per chunk, and can end it three ways: a clean end, a dropped
# connection (no terminating chunk) or a stall (the rest of the body arrives late).
RSpec.describe Coolhand::NetHttpInterceptor, "abandoned streams (stream_incomplete)" do # rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
  let(:server) { TCPServer.new("127.0.0.1", 0) }
  let(:port) { server.addr[1] }
  let(:http_class) { Class.new(Net::HTTP) { prepend Coolhand::NetHttpInterceptor } }
  let(:logs) { [] }
  let(:events) { ["data: {\"a\":1}\n\n", "data: {\"b\":2}\n\n", "data: [DONE]\n\n"] }

  def serve_stream(pieces, ending: :clean)
    Thread.new do
      client = server.accept
      client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      head = client.gets("\r\n\r\n")
      # Drain the request body too: closing a socket with unread data sends a RST on Linux, which the
      # client sees as ECONNRESET instead of the EOFError a clean close gives.
      client.read(head[/content-length:\s*(\d+)/i, 1].to_i)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n" \
                   "Connection: close\r\n\r\n")
      pieces.each do |piece|
        client.write("#{piece.bytesize.to_s(16)}\r\n#{piece}\r\n")
        sleep 0.03
      end
      sleep 0.2 if ending == :stall
      client.write("0\r\n\r\n") unless ending == :drop
      client.close
    rescue IOError, SystemCallError
      nil
    end
  end

  # How a cut-short chunked body surfaces depends on the platform's TCP close behaviour.
  def expect_dropped_connection(&block)
    expect(&block).to(raise_error { |error| expect([EOFError, Errno::ECONNRESET]).to include(error.class) })
  end

  def stream_request(&block)
    http_class.new("127.0.0.1", port).request(Net::HTTP::Post.new("/v1/stream").tap { |r| r.body = "{}" }, &block)
  end

  def raw
    logs.first.fetch(:raw_request)
  end

  before do
    allow(Coolhand).to receive(:log)
    api_service = instance_double(Coolhand::ApiService)
    allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
    allow(api_service).to receive(:send_llm_request_log) { |arg| logs << arg }
    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["127.0.0.1"]
    end
    WebMock.disable!
  end

  after do
    WebMock.enable!
    server.close
  end

  it "sends no stream_incomplete field for a stream read to its end" do
    served = serve_stream(events)

    received = +""
    stream_request { |res| res.read_body { |chunk| received << chunk } }
    served.join

    expect(received).to eq(events.join)
    expect(logs.size).to eq(1)
    expect(raw[:response_body]).to eq(events.join)
    expect(raw).not_to have_key(:stream_incomplete)
    expect(raw[:is_streaming]).to be true
  end

  it "sends no stream_incomplete field when the host never calls read_body and Net::HTTP reads the body" do
    served = serve_stream(events)

    stream_request(&:code)
    served.join

    expect(logs.size).to eq(1)
    expect(raw[:response_body]).to eq(events.join)
    expect(raw).not_to have_key(:stream_incomplete)
  end

  it "sends no stream_incomplete field for a non-streaming request" do
    served = serve_stream(events)

    http_class.new("127.0.0.1", port).request(Net::HTTP::Post.new("/v1/stream"))
    served.join

    expect(logs.size).to eq(1)
    expect(raw[:is_streaming]).to be false
    expect(raw).not_to have_key(:stream_incomplete)
  end

  it "sends the partial body with stream_incomplete: true when the host breaks out of read_body mid-stream" do
    served = serve_stream(events, ending: :stall)

    received = []
    stream_request do |res|
      res.read_body do |chunk|
        received << chunk
        break if received.size == 2
      end
    end
    served.join

    expect(received).to eq(events.first(2))
    expect(logs.size).to eq(1)
    expect(raw[:stream_incomplete]).to be true
    expect(raw[:response_body]).to eq(events.first(2).join)
    expect(raw[:status_code]).to eq(200)
    expect(raw[:is_streaming]).to be true
  end

  it "marks a stream abandoned right after the provider terminator, even though the last frame was seen" do
    served = serve_stream(events, ending: :stall)

    stream_request do |res|
      res.read_body { |chunk| break if chunk.include?("[DONE]") }
    end
    served.join

    expect(logs.size).to eq(1)
    expect(raw[:stream_incomplete]).to be true
    expect(raw[:response_body]).to eq(events.join)
  end

  it "marks a stream cancelled with throw" do
    served = serve_stream(events, ending: :stall)

    catch(:cancel) do
      stream_request { |res| res.read_body { |_chunk| throw :cancel } }
    end
    served.join

    expect(logs.size).to eq(1)
    expect(raw[:stream_incomplete]).to be true
    expect(raw[:response_body]).to eq(events.first)
  end

  it "sends the partial body when the host's block raises mid-stream, and re-raises to the host" do
    served = serve_stream(events, ending: :stall)

    seen = 0
    expect do
      stream_request do |res|
        res.read_body do |_chunk|
          seen += 1
          raise ArgumentError, "consumer gave up" if seen == 2
        end
      end
    end.to raise_error(ArgumentError, "consumer gave up")
    served.join

    expect(logs.size).to eq(1)
    expect(raw[:stream_incomplete]).to be true
    expect(raw[:response_body]).to eq(events.first(2).join)
    expect(raw[:status_code]).to eq(200)
  end

  it "sends the partial body when the connection is dropped mid-stream" do
    served = serve_stream(events.first(2), ending: :drop)

    expect_dropped_connection { stream_request { |res| res.read_body { |_chunk| nil } } }
    served.join

    expect(logs.size).to eq(1)
    expect(raw[:stream_incomplete]).to be true
    expect(raw[:response_body]).to eq(events.first(2).join)
    expect(raw[:status_code]).to eq(200)
  end

  it "leaves a response abandoned before any of it was read unmarked, since there is no partial body" do
    served = serve_stream(events, ending: :stall)

    stream_request { |_res| break }
    served.join

    expect(logs.size).to eq(1)
    expect(raw).not_to have_key(:stream_incomplete)
    expect(raw[:response_body]).to be_nil
  end

  it "keeps the error record, unmarked, when the connection drops before the first chunk arrives" do
    served = serve_stream([], ending: :drop)

    expect_dropped_connection { stream_request { |res| res.read_body { |_chunk| nil } } }
    served.join

    expect(logs.size).to eq(1)
    expect(raw).not_to have_key(:stream_incomplete)
    expect(raw[:response_body]).to include("error" => hash_including("class" => a_string_matching(/\AEOFError|Errno::ECONNRESET\z/)))
  end

  it "does not mark a stream the host fully read but then raised on" do
    served = serve_stream(events)

    expect do
      stream_request do |res|
        res.read_body { |_chunk| nil }
        raise ArgumentError, "bad status"
      end
    end.to raise_error(ArgumentError)
    served.join

    expect(logs.size).to eq(1)
    expect(raw).not_to have_key(:stream_incomplete)
  end

  it "logs a connection failure before any response as an error, not as an abandoned stream" do
    server.close
    refused = TCPServer.new("127.0.0.1", 0)
    dead_port = refused.addr[1]
    refused.close

    expect do
      http_class.new("127.0.0.1", dead_port).request(Net::HTTP::Post.new("/v1/stream")) { |res| res.read_body { nil } }
    end.to raise_error(SystemCallError)

    expect(logs.size).to eq(1)
    expect(raw).not_to have_key(:stream_incomplete)
    expect(raw[:response_body]).to include("error")
  end

  describe "the capture cap" do
    let(:events) { Array.new(4) { |i| "piece-#{i}-".ljust(25, "x") } }

    before { Coolhand.configuration.max_captured_body_bytes = 40 }

    it "does not mark a truncated stream that was read to its end" do
      served = serve_stream(events)

      stream_request { |res| res.read_body { |_chunk| nil } }
      served.join

      expect(raw[:response_body]).to include("_coolhand_capture_skipped" => "body_too_large")
      expect(raw).not_to have_key(:stream_incomplete)
    end

    it "marks a stream that is both truncated and abandoned" do
      served = serve_stream(events, ending: :stall)

      count = 0
      stream_request { |res| res.read_body { |_chunk| break if (count += 1) == 3 } }
      served.join

      expect(raw[:stream_incomplete]).to be true
      expect(raw[:response_body]).to include("_coolhand_capture_skipped" => "body_too_large", "size_bytes" => 75)
    end
  end

  it "logs a partial body cut inside a multibyte character as valid UTF-8, still as one record" do
    served = serve_stream(["data: {\"t\":\"caf\xC3".b, "\xA9\"}\n\n".b], ending: :stall)
    expect do
      stream_request { |res| res.read_body { |_chunk| raise "host failed" } }
    end.to raise_error(RuntimeError, "host failed")
    served.join

    expect(logs.size).to eq(1)
    expect { JSON.generate(logs.first) }.not_to raise_error
    expect(raw[:response_body]).to eq("data: {\"t\":\"caf")
    expect(raw[:stream_incomplete]).to be true
  end

  it "logs a partial body cut inside a multibyte character as valid UTF-8 after a break too" do
    served = serve_stream(["data: {\"t\":\"caf\xC3".b, "\xA9\"}\n\n".b], ending: :stall)
    stream_request { |res| res.read_body { |_chunk| break } }
    served.join

    expect(logs.size).to eq(1)
    expect { JSON.generate(logs.first) }.not_to raise_error
    expect(raw[:response_body]).to eq("data: {\"t\":\"caf")
    expect(raw[:stream_incomplete]).to be true
  end

  it "releases the capture state after an abandoned stream, so the next call starts clean" do
    served = serve_stream(events, ending: :stall)
    stream_request { |res| res.read_body { |_chunk| break } }
    served.join

    expect(Thread.current[:coolhand_stream_buffer]).to be_nil
    expect(Thread.current[:coolhand_capturing_stream]).to be_nil
    expect(Thread.current[:coolhand_stream_read]).to be_nil
  end

  it "does not leak an abandoned outer stream's state into a nested request's record" do
    nested = TCPServer.new("127.0.0.1", 0)
    nested_thread = Thread.new do
      client = nested.accept
      client.gets("\r\n\r\n")
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n" \
                   "Connection: close\r\n\r\n{}")
      client.close
    end
    served = serve_stream(events, ending: :stall)

    stream_request do |res|
      res.read_body do |_chunk|
        http_class.new("127.0.0.1", nested.addr[1]).request(Net::HTTP::Get.new("/inner")) do |inner_res|
          inner_res.read_body { |_inner_chunk| nil }
        end
        break
      end
    end
    served.join
    nested_thread.join
    nested.close

    expect(logs.size).to eq(2)
    inner, outer = logs.map { |l| l.fetch(:raw_request) }
    expect(inner).not_to have_key(:stream_incomplete)
    expect(outer[:stream_incomplete]).to be true
  end
end
