# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"
require "socket"
require "stringio"

# Chunked (no Content-Length) body_stream requests over a real socket: WebMock's adapter reads the
# whole stream itself, so it can't show what Net::HTTP actually puts on the wire or how the stream
# is read.
RSpec.describe Coolhand::NetHttpInterceptor, "chunked body_stream capture" do # rubocop:disable RSpec/DescribeMethod
  # A stream that only has #read (no #readpartial, no #to_io), serving fixed pieces one per call.
  let(:read_only_stream_class) do
    Class.new do
      attr_reader :read_calls

      def initialize(pieces)
        @pieces = pieces.dup
        @read_calls = []
      end

      def read(length = nil, outbuf = nil)
        @read_calls << length
        piece = @pieces.shift
        return (length.nil? ? +"" : nil) if piece.nil?

        outbuf ? outbuf.replace(piece) : piece.dup
      end
    end
  end

  let(:server) { TCPServer.new("127.0.0.1", 0) }
  let(:port) { server.addr[1] }
  let(:http_class) { Class.new(Net::HTTP) { prepend Coolhand::NetHttpInterceptor } }
  let(:logs) { [] }

  # Accepts one connection, decodes its chunked request body and answers with a small JSON 200.
  # The thread's value is [request_head, raw_chunk_sizes, body].
  def serve_one_chunked_request
    Thread.new do
      client = server.accept
      head = client.gets("\r\n\r\n")
      body = +""
      sizes = []
      loop do
        size = client.gets("\r\n").to_i(16)
        break if size.zero?

        sizes << size
        body << client.read(size)
        client.read(2)
      end
      client.gets("\r\n")
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n" \
                   "Connection: close\r\n\r\n{\"ok\":true}")
      client.close
      [head, sizes, body]
    end
  end

  def chunked_post(stream)
    req = Net::HTTP::Post.new("/upload")
    req["Transfer-Encoding"] = "chunked"
    req["Content-Type"] = "application/json"
    req.body_stream = stream
    req
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

  def send_chunked(stream)
    served = serve_one_chunked_request
    response = http_class.new("127.0.0.1", port).request(chunked_post(stream))
    [response, served.value]
  end

  it "sends a chunked JSON body unchanged and logs it, without reading the stream ahead of the send" do
    pieces = ['{"messages":[', '{"role":"user","content":"hi"}', "]}"]
    stream = read_only_stream_class.new(pieces)

    response, (_head, _sizes, wire_body) = send_chunked(stream)

    expect(response.code).to eq("200")
    expect(wire_body).to eq(pieces.join)
    expect(logs.size).to eq(1)
    expect(logs.first[:raw_request][:request_body])
      .to eq({ "messages" => [{ "role" => "user", "content" => "hi" }] })
    # Read in Net::HTTP's own copy chunks (copy_stream passes a length), never one unbounded read.
    expect(stream.read_calls.compact).not_to be_empty
    expect(stream.read_calls).not_to include(nil)
  end

  it "puts the host's own stream back on the request once it has been sent" do
    stream = StringIO.new('{"a":1}')
    req = chunked_post(stream)
    served = serve_one_chunked_request

    http_class.new("127.0.0.1", port).request(req)
    served.join

    expect(req.body_stream).to equal(stream)
  end

  it "streams an oversized chunked body in full while logging only a marker" do
    Coolhand.configuration.max_captured_body_bytes = 40
    pieces = Array.new(6) { |i| "piece-#{i}-".ljust(30, "x") }
    stream = read_only_stream_class.new(pieces)

    response, (_head, _sizes, wire_body) = send_chunked(stream)

    expect(response.code).to eq("200")
    expect(wire_body).to eq(pieces.join)
    expect(logs.first[:raw_request][:request_body]).to include(
      "_coolhand_capture_skipped" => "body_too_large", "size_bytes" => pieces.join.bytesize, "max_bytes" => 40,
      "content_type" => "application/json"
    )
  end

  it "works with a stream that has #readpartial (a pipe), sending every byte" do
    reader, writer = IO.pipe
    body = '{"streamed":"through a pipe"}'
    writer.write(body)
    writer.close

    _response, (_head, _sizes, wire_body) = send_chunked(reader)

    expect(wire_body).to eq(body)
    expect(logs.first[:raw_request][:request_body]).to eq({ "streamed" => "through a pipe" })
  ensure
    reader&.close
  end

  it "works with a File (which IO.copy_stream would otherwise read around the tap)" do
    body = '{"streamed":"from a file"}'
    Tempfile.create("coolhand-chunked") do |file|
      file.write(body)
      file.rewind

      _response, (_head, _sizes, wire_body) = send_chunked(file)

      expect(wire_body).to eq(body)
      expect(logs.first[:raw_request][:request_body]).to eq({ "streamed" => "from a file" })
    end
  end

  it "logs a body_stream_incomplete marker, and restores the stream, when the request fails before the send" do
    dead = TCPServer.new("127.0.0.1", 0)
    dead_port = dead.addr[1]
    dead.close
    stream = StringIO.new('{"never":"sent"}')
    req = chunked_post(stream)

    expect { http_class.new("127.0.0.1", dead_port).request(req) }.to raise_error(SystemCallError)

    expect(logs.first[:raw_request][:request_body]).to include(
      "_coolhand_capture_skipped" => "body_stream_incomplete", "size_bytes" => 0
    )
    expect(req.body_stream).to equal(stream)
  end

  it "lets an error raised by the host's stream reach the host exactly as without the gem" do
    failing = Object.new
    def failing.read(*) = raise(IOError, "disk gone")
    server_thread = Thread.new { server.accept.tap { |c| c.gets("\r\n\r\n") }.close }

    expect { http_class.new("127.0.0.1", port).request(chunked_post(failing)) }
      .to raise_error(IOError, "disk gone")
    server_thread.join
  end

  it "does not read a chunked stream's content while only deciding what to capture" do
    stream = StringIO.new('{"a":1}')
    allow(stream).to receive(:read).and_call_original
    req = chunked_post(stream)

    Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil)

    expect(stream).not_to have_received(:read)
  end
end
