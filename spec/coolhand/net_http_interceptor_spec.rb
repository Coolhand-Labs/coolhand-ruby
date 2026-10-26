# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"
require "socket"
require "stringio"
require "timeout"

RSpec.describe Coolhand::NetHttpInterceptor do
  let(:api_service_instance) { instance_double(Coolhand::ApiService) }
  let(:api_service_class) { class_double(Coolhand::ApiService).as_stubbed_const }

  before do
    allow(Coolhand).to receive(:log)

    # capture the argument passed to send_llm_request_log for easier assertions (handles streaming adapters)
    @captured_log = nil
    allow(api_service_class).to receive(:new).and_return(api_service_instance)
    allow(api_service_instance).to receive(:send_llm_request_log) do |arg|
      @captured_log = arg
    end

    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
      c.intercept_addresses = ["api.test.com"]
    end
  end

  it "intercepts a Net::HTTP request and logs the response body" do
    stub_request(:get, "https://api.test.com/hello")
      .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/hello")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri)

    http.request(req)

    # Allow any background thread (if used) to run
    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw).to be_a(Hash)
    expect(raw[:url] || raw["url"]).to eq("https://api.test.com/hello")
    expect((raw[:method] || raw["method"]).to_s).to match(/get/i)
    expect(raw[:response_body] || raw["response_body"]).to eq({ "msg" => "hi" })
    expect(raw[:status_code] || raw["status_code"]).to eq(200)
    expect(raw).not_to have_key(:source_api)
    expect(raw).not_to have_key(:model)
  end

  describe "Net::HTTP method pollution" do
    it "adds nothing but #request to Net::HTTP" do
      expect(described_class.public_instance_methods(false)).to eq([:request])
      expect(described_class.private_instance_methods(false)).to be_empty
      expect(Net::HTTP.ancestors).not_to include(Coolhand::BaseInterceptor)
    end

    it "keeps the generically named helpers off Net::HTTP instances" do
      described_class.patch!
      http = Net::HTTP.new("api.test.com", 443)

      %i[parse_json sanitize_url sanitize_headers intercept? send_complete_request_log].each do |name|
        expect(http.respond_to?(name, true)).to be(false), "expected Net::HTTP not to respond to #{name}"
      end
    end
  end

  describe "re-entry guard" do
    before(:each) do
      stub_request(:get, "https://api.test.com/hello")
        .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })
    end

    it "logs exactly once with Net::HTTP.new(...).request(req) (bare new pattern)" do
      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      http.request(req)
      sleep 0.05

      expect(api_service_instance).to have_received(:send_llm_request_log).once
    end

    it "logs exactly once with Net::HTTP.start(...) { |h| h.request(req) } pattern" do
      uri = URI("https://api.test.com/hello")
      req = Net::HTTP::Get.new(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      sleep 0.05

      expect(api_service_instance).to have_received(:send_llm_request_log).once
    end

    it "logs independent requests made on a different connection inside a response callback" do
      stub_request(:get, "https://api.test.com/second")
        .to_return(status: 200, body: '{"msg":"second"}', headers: { "Content-Type" => "application/json" })

      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      uri1 = URI("https://api.test.com/hello")
      req1 = Net::HTTP::Get.new(uri1)
      Net::HTTP.start(uri1.host, uri1.port, use_ssl: true) do |http|
        http.request(req1) do |_res|
          uri2 = URI("https://api.test.com/second")
          http2 = Net::HTTP.new(uri2.host, uri2.port)
          http2.use_ssl = true
          http2.request(Net::HTTP::Get.new(uri2))
        end
      end
      sleep 0.05

      expect(logs.size).to eq(2)
    end
  end

  it "captures streaming responses via read_body and marks is_streaming" do
    stub_request(:get, "https://api.test.com/stream")
      .to_return(status: 200, body: "chunk1chunk2", headers: { "Content-Type" => "application/octet-stream" })

    uri = URI("https://api.test.com/stream")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri)

    # Use request with block and read_body to trigger streaming path
    http.request(req) do |res|
      res.read_body do |chunk|
        # consumer would process chunks here
      end
    end

    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw).to be_a(Hash)
    expect(raw[:url] || raw["url"]).to eq("https://api.test.com/stream")
    expect(raw[:is_streaming] || raw["is_streaming"]).to be true
    # Accept any non-nil response_body (string or streaming adapter)
    resp_body = raw[:response_body] || raw["response_body"]
    expect(resp_body).not_to be_nil
  end

  # WebMock defines read_body as a singleton on its stubbed responses, which bypasses the prepended
  # ResponseInterceptor entirely, so the buffer is exercised directly here and over a real socket below.
  describe Coolhand::NetHttpInterceptor::ResponseInterceptor do
    let(:response_class) do
      base = Class.new do
        def read_body(dest = nil, &block)
          return "unblocked-body" unless block

          %w[chunk1 chunk2].each(&block)
          dest
        end
      end
      Class.new(base) { include Coolhand::NetHttpInterceptor::ResponseInterceptor }
    end
    let(:response) { response_class.new }

    after do
      Thread.current[:coolhand_stream_buffer] = nil
      Thread.current[:coolhand_capturing_stream] = nil
    end

    it "accumulates yielded chunks into the thread-local buffer while a request is capturing, " \
       "and still yields every chunk to the consumer" do
      Thread.current[:coolhand_capturing_stream] = response
      chunks = []

      response.read_body { |chunk| chunks << chunk }

      expect(chunks).to eq(%w[chunk1 chunk2])
      expect(Thread.current[:coolhand_stream_buffer]).to eq("chunk1chunk2")
    end

    it "does not buffer a different response than the one being captured" do
      Thread.current[:coolhand_capturing_stream] = response_class.new
      chunks = []

      response.read_body { |chunk| chunks << chunk }

      expect(chunks).to eq(%w[chunk1 chunk2])
      expect(Thread.current[:coolhand_stream_buffer]).to be_nil
    end

    it "does not buffer when no intercepted request is capturing" do
      chunks = []

      response.read_body { |chunk| chunks << chunk }

      expect(chunks).to eq(%w[chunk1 chunk2])
      expect(Thread.current[:coolhand_stream_buffer]).to be_nil
    end

    it "passes a blockless read_body straight through without touching the buffer" do
      Thread.current[:coolhand_capturing_stream] = response

      expect(response.read_body).to eq("unblocked-body")
      expect(Thread.current[:coolhand_stream_buffer]).to be_nil
    end
  end

  it "logs the streamed response_body assembled from block-form read_body chunks over a real connection" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    body = "chunk1chunk2"
    server_thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n")
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
      client.close
    end
    Coolhand.configuration.intercept_addresses = ["127.0.0.1"]

    begin
      # WebMock swaps out Net::HTTP (and its read_body never reaches the interceptor), so use the real
      # class via a throwaway subclass instead of patching the global one.
      WebMock.disable!
      http_class = Class.new(Net::HTTP) { prepend Coolhand::NetHttpInterceptor }
      chunks = []
      http_class.start("127.0.0.1", port) do |http|
        http.request(Net::HTTP::Get.new("/stream")) do |res|
          res.read_body { |chunk| chunks << chunk }
        end
      end

      raw = @captured_log[:raw_request]
      expect(chunks.join).to eq(body)
      expect(raw[:response_body]).to eq(body)
      expect(raw[:is_streaming]).to be true
      expect(Thread.current[:coolhand_stream_buffer]).to be_nil
      expect(Thread.current[:coolhand_capturing_stream]).to be_nil
    ensure
      WebMock.enable!
      server_thread.kill
      server.close
    end
  end

  # Real-socket helpers: WebMock's stubbed responses bypass the prepended ResponseInterceptor, so the
  # nesting and host-block-error behavior has to be exercised over a real connection.
  describe "streaming capture over a real connection" do
    let(:server) { TCPServer.new("127.0.0.1", 0) }
    let(:port) { server.addr[1] }
    let(:http_class) { Class.new(Net::HTTP) { prepend Coolhand::NetHttpInterceptor } }

    # Serves "outer-body" for /outer, "NESTED-SECRET" for everything else (one connection per request).
    before do
      @server_thread = Thread.new do
        loop do
          client = server.accept
          path = client.gets.to_s.split[1]
          client.gets("\r\n\r\n")
          body = path == "/outer" ? "outer-body" : "NESTED-SECRET"
          client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                       "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        end
      rescue IOError, Errno::EBADF
        nil
      end
      Coolhand.configuration.intercept_addresses = ["127.0.0.1"]
      WebMock.disable!
    end

    after do
      WebMock.enable!
      @server_thread.kill
      server.close
    end

    def stream_get(path, &block)
      http_class.start("127.0.0.1", port) do |http|
        http.request(Net::HTTP::Get.new(path), &block)
      end
    end

    it "does not append chunks of a non-intercepted nested request to the outer request's log" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      stream_get("/outer") do |res|
        res.read_body do |_chunk|
          # excluded by the default /batchPredictionJobs/ pattern, so this request is never intercepted
          stream_get("/batchPredictionJobs/nested") { |inner| inner.read_body { |_c| nil } }
        end
      end

      expect(logs.size).to eq(1)
      expect(logs.first[:raw_request][:response_body]).to eq("outer-body")
    end

    it "logs an intercepted nested request's own chunks without mixing them into the outer log" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      stream_get("/outer") do |res|
        res.read_body do |_chunk|
          stream_get("/inner") { |inner| inner.read_body { |_c| nil } }
        end
      end

      bodies = logs.map { |l| l[:raw_request][:response_body] }
      expect(bodies).to contain_exactly("outer-body", "NESTED-SECRET")
    end

    it "logs only the class of an error raised in the host's streaming block, never its message" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      expect do
        stream_get("/outer") do |res|
          res.read_body { |_chunk| raise ArgumentError, "app-level secret: user 42" }
        end
      end.to raise_error(ArgumentError, "app-level secret: user 42")

      error = logs.first[:raw_request][:response_body]["error"]
      expect(error["class"]).to eq("ArgumentError")
      expect(error["message"]).to eq("[redacted: raised in host streaming block]")
      expect(logs.first.to_s).not_to include("app-level secret")
    end

    it "keeps the message of a transport error that surfaces inside the host's streaming block" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      expect do
        stream_get("/outer") { |res| res.read_body { |_c| raise IOError, "closed stream" } }
      end.to raise_error(IOError)

      error = logs.first[:raw_request][:response_body]["error"]
      expect(error["message"]).to eq("closed stream")
    end

    it "derives no status code from a host-block error" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      expect do
        stream_get("/outer") { |res| res.read_body { |_c| raise ArgumentError, "upstream status=502" } }
      end.to raise_error(ArgumentError)

      expect(logs.first[:raw_request][:status_code]).to be_nil
    end

    it "captures only the intercepted response when the host streams via Net::HTTP#get with a block" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }
      chunks = []

      http_class.start("127.0.0.1", port) do |http|
        http.get("/outer") do |chunk|
          chunks << chunk
          http_class.start("127.0.0.1", port) { |h2| h2.get("/batchPredictionJobs/nested") { |_c| nil } }
        end
      end

      expect(chunks.join).to eq("outer-body")
      expect(logs.size).to eq(1)
      expect(logs.first[:raw_request][:response_body]).to eq("outer-body")
    end

    it "captures a streaming request made on an unstarted connection (request re-enters through start)" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      http_class.new("127.0.0.1", port).request(Net::HTTP::Get.new("/outer")) { |res| res.read_body { |_c| nil } }

      expect(logs.size).to eq(1)
      expect(logs.first[:raw_request][:response_body]).to eq("outer-body")
    end

    it "keeps buffering the outer response after a nested intercepted request raises" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      stream_get("/outer") do |res|
        res.read_body do |_chunk|
          stream_get("/inner") { |inner| inner.read_body { |_c| raise "nested boom" } }
        rescue RuntimeError
          nil
        end
      end

      outer = logs.find { |l| l[:raw_request][:url].end_with?("/outer") }
      expect(outer[:raw_request][:response_body]).to eq("outer-body")
    end

    it "still logs a transport error's message" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }
      dead = TCPServer.new("127.0.0.1", 0)
      dead_port = dead.addr[1]
      dead.close

      expect do
        http_class.new("127.0.0.1", dead_port).request(Net::HTTP::Get.new("/x"))
      end.to raise_error(SystemCallError)

      error = logs.first[:raw_request][:response_body]["error"]
      expect(error["class"]).to match(/ECONNREFUSED/)
      expect(error["message"]).to match(/refused/i)
    end

    it "still logs and lets the host break out of the request block, restoring the capture state" do
      logs = []
      allow(api_service_instance).to receive(:send_llm_request_log) { |arg| logs << arg }

      result = http_class.start("127.0.0.1", port) do |http|
        http.request(Net::HTTP::Get.new("/outer")) do |res|
          res.read_body { |_chunk| nil }
          break :broke
        end
      end

      expect(result).to eq(:broke)
      expect(logs.size).to eq(1)
      expect(Thread.current[:coolhand_capturing_stream]).to be_nil
      expect(Thread.current[:coolhand_stream_buffer]).to be_nil
    end
  end

  it "does not emit a JSON BINARY encoding warning when streaming multi-byte UTF-8 content" do
    multibyte_body = "{\"text\":\"こんにちは世界\"}".b
    stub_request(:post, "https://api.test.com/stream")
      .to_return(status: 200, body: multibyte_body, headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/stream")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body = "{\"messages\":[]}"

    chunks = []
    expect do
      http.request(req) do |res|
        res.read_body { |chunk| chunks << chunk }
      end
      sleep 0.05
    end.not_to output(/BINARY/).to_stderr
  end

  describe "capture control" do
    before(:each) do
      stub_request(:get, "https://api.test.com/hello")
        .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })
    end

    def make_request
      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      http.request(req)
      sleep 0.05
    end

    context "with default config (capture: true)" do
      it "captures requests by default" do
        make_request
        expect(@captured_log).to be_a(Hash)
      end

      it "does not capture inside without_capture block" do
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_nil
      end

      it "still captures inside with_capture block" do
        Coolhand.with_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end
    end

    context "with capture: false" do
      before do
        Coolhand.configuration.capture = false
      end

      it "does not capture requests by default" do
        make_request
        expect(@captured_log).to be_nil
      end

      it "captures inside with_capture block" do
        Coolhand.with_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end

      it "does not capture inside without_capture block" do
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_nil
      end
    end

    context "with debug_mode: true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "captures even inside without_capture block" do
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end

      it "captures when capture config is false" do
        Coolhand.configuration.capture = false
        make_request
        expect(@captured_log).to be_a(Hash)
      end

      it "captures when capture config is false AND inside without_capture" do
        Coolhand.configuration.capture = false
        Coolhand.without_capture do
          make_request
        end
        expect(@captured_log).to be_a(Hash)
      end
    end
  end

  describe ".patch!" do
    it "is idempotent and prepends module to Net::HTTP ancestors" do
      # Call patch! multiple times to ensure no errors and presence in ancestor chain
      expect { described_class.patch! }.not_to raise_error
      expect { described_class.patch! }.not_to raise_error

      expect(Net::HTTP.ancestors).to include(described_class)
    end

    it "rolls back both the refcount and the patched flag when the underlying patch step raises" do
      described_class.reset!
      allow(Net::HTTPResponse).to receive(:prepend).and_raise("boom from prepend")

      expect { described_class.patch! }.to raise_error("boom from prepend")

      expect(described_class.patched?).to be false

      # A subsequent, successful patch!/unpatch! pair must still balance cleanly — proves the
      # failed call above left no leaked refcount behind.
      allow(Net::HTTPResponse).to receive(:prepend).and_call_original
      described_class.patch!
      expect(described_class.patched?).to be true
      described_class.unpatch!
      expect(described_class.patched?).to be false
    end
  end

  describe ".unpatch!" do
    it "marks the interceptor as unpatched so guarded requests fall through to the real implementation" do
      described_class.reset!
      described_class.patch!
      expect(described_class.patched?).to be true

      described_class.unpatch!

      expect(described_class.patched?).to be false
    end

    it "stays patched while a second overlapping patch! is still outstanding" do
      described_class.reset!
      described_class.patch! # outer holder starts
      described_class.patch! # inner overlapping holder starts

      described_class.unpatch! # inner finishes first
      expect(described_class.patched?).to be true

      described_class.unpatch! # outer finishes
      expect(described_class.patched?).to be false
    end

    it "does not log a spurious 'disabled' message on an unbalanced extra unpatch! call" do
      described_class.reset!

      described_class.unpatch! # no matching patch! — a caller bug, but must be a harmless no-op

      expect(described_class.patched?).to be false
      expect(Coolhand).not_to have_received(:log).with(/disabled/)
    end
  end

  # Integration-level sanity check that Coolhand.capture composes correctly across threads.
  # This does NOT reproduce the original TOCTOU race itself (that requires two threads reading
  # a stale `patched?` snapshot at the same instant, which can't be forced deterministically
  # through the public API) — the deterministic regression coverage for the race is the
  # ".unpatch!" example above ("stays patched while a second overlapping patch! is still
  # outstanding").
  describe "overlapping Coolhand.capture blocks" do
    it "keeps requests intercepted for an overlapping in-flight capture block" do
      described_class.reset!
      stub_request(:get, "https://api.test.com/hello")
        .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })

      release_outer = Queue.new
      outer_started = Queue.new

      outer = Thread.new do
        Coolhand.capture do
          outer_started << true
          release_outer.pop
        end
      end

      begin
        # Bounded, not an unbounded #pop: if the outer thread's Coolhand.capture block raised
        # before ever reaching `outer_started << true` (e.g. patch! itself failed), we'd
        # otherwise block here forever with no way to reach the `ensure` below.
        Timeout.timeout(2) { outer_started.pop }
        expect(Coolhand::NetHttpInterceptor.patched?).to be true

        uri = URI("https://api.test.com/hello")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        # Synchronous: NetHttpInterceptor#request calls the stubbed ApiService synchronously
        # (see the `before` block above), so @captured_log is populated before capture returns.
        Coolhand.capture { http.request(Net::HTTP::Get.new(uri)) }

        expect(@captured_log).to be_a(Hash)
        expect(Coolhand::NetHttpInterceptor.patched?).to be true
      ensure
        # Always release and join the outer thread, even if an assertion above failed, so a
        # failing example doesn't leak a thread blocked forever on release_outer.pop. Bounded
        # with a timeout + kill as a last resort in case the outer thread is wedged some other way.
        release_outer << true
        outer.join(2)
        outer.kill if outer.alive?
      end

      expect(Coolhand::NetHttpInterceptor.patched?).to be false
    end
  end

  it "captures the request body when set via body_stream instead of #body" do
    stub_request(:post, "https://api.test.com/upload")
      .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body_stream = StringIO.new('{"streamed":true}')
    req["Content-Length"] = req.body_stream.size.to_s

    http.request(req)
    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw[:request_body] || raw["request_body"]).to eq({ "streamed" => true })
  end

  it "still attempts (and logs) the real request even when capturing the request body raises" do
    stub_request(:post, "https://api.test.com/upload")
      .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    # Raise only on the first #read (simulating capture_request_body hitting
    # a transient failure) so the real send below it can still succeed —
    # proving execution reaches `super` instead of aborting before it.
    call_count = 0
    stream = StringIO.new('{"streamed":true}')
    allow(stream).to receive(:read) do
      call_count += 1
      raise(IOError, "stream already consumed") if call_count == 1

      '{"streamed":true}'
    end
    req.body_stream = stream
    req["Content-Length"] = "18"

    response = nil
    expect { response = http.request(req) }.not_to raise_error
    sleep 0.05

    expect(call_count).to be >= 2
    expect(response.code).to eq("200")
    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw[:request_body] || raw["request_body"]).to be_nil
  end

  it "replaces an oversized body_stream with a truncation marker in the log, but still sends it in full" do
    Coolhand.configuration.max_captured_body_bytes = 10
    content = '{"streamed":"this payload is well over ten bytes long"}'

    stub_request(:post, "https://api.test.com/upload")
      .with(body: content)
      .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body_stream = StringIO.new(content)
    req["Content-Length"] = content.bytesize.to_s

    response = http.request(req)
    sleep 0.05

    expect(response.code).to eq("200")
    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    body = raw[:request_body] || raw["request_body"]
    expect(body["_coolhand_capture_skipped"]).to eq("body_too_large")
    expect(body["size_bytes"]).to eq(content.bytesize)
    expect(body["max_bytes"]).to eq(10)
  end

  it "skips capturing a non-JSON content-type body_stream without reading/rewrapping it, but still sends it in full" do
    content = (+"\xFF\xD8\xFF\xE0binary-ish-audio-bytes").force_encoding("BINARY")

    stub_request(:post, "https://api.test.com/upload")
      .with(body: content)
      .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

    uri = URI("https://api.test.com/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.content_type = "audio/mpeg"
    stream = StringIO.new(content)
    req.body_stream = stream
    req["Content-Length"] = content.bytesize.to_s

    response = http.request(req)
    sleep 0.05

    expect(response.code).to eq("200")
    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    body = raw[:request_body] || raw["request_body"]
    expect(body["_coolhand_capture_skipped"]).to eq("non_json_content_type")
    expect(body["content_type"]).to eq("audio/mpeg")
  end

  it "never reads a non-JSON content-type body_stream while capturing (avoids the double memory hold)" do
    uri = URI("https://api.test.com/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.content_type = "multipart/form-data; boundary=x"
    stream = StringIO.new("some large binary upload")
    allow(stream).to receive(:read).and_call_original
    req.body_stream = stream

    captured = Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil)

    expect(stream).not_to have_received(:read)
    expect(req.body_stream).to equal(stream)
    expect(captured["_coolhand_capture_skipped"]).to eq("non_json_content_type")
    expect(captured["content_type"]).to eq("multipart/form-data")
  end

  describe "request body_stream Content-Length pre-check" do
    let(:uri) { URI("https://api.test.com/upload") }
    let(:content) { '{"streamed":"this payload is well over ten bytes long"}' }
    let(:http) { Net::HTTP.new(uri.host, uri.port).tap { |h| h.use_ssl = true } }

    def stream_request(stream, content_length: content.bytesize.to_s)
      req = Net::HTTP::Post.new(uri)
      req.body_stream = stream
      req["Content-Length"] = content_length if content_length
      req
    end

    before { Coolhand.configuration.max_captured_body_bytes = 10 }

    it "skips an oversized declared Content-Length without reading or rewrapping the stream" do
      stream = StringIO.new(content)
      allow(stream).to receive(:read).and_call_original
      req = stream_request(stream)

      captured = Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil)

      expect(stream).not_to have_received(:read)
      expect(req.body_stream).to equal(stream)
      expect(captured).to include(
        "_coolhand_capture_skipped" => "body_too_large", "size_bytes" => content.bytesize, "max_bytes" => 10
      )
    end

    it "still sends the full body to the provider when the capture is skipped up front" do
      stub = stub_request(:post, "https://api.test.com/upload").with(body: content)
        .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

      http.request(stream_request(StringIO.new(content)))
      sleep 0.05

      expect(stub).to have_been_requested
      raw = @captured_log[:raw_request]
      expect(raw[:request_body]["_coolhand_capture_skipped"]).to eq("body_too_large")
    end

    it "reads and captures a stream whose declared Content-Length is within the cap" do
      Coolhand.configuration.max_captured_body_bytes = 1_000
      req = stream_request(StringIO.new(content))

      captured = Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil)

      expect(captured).to eq({ "streamed" => "this payload is well over ten bytes long" })
    end

    it "taps the stream instead of reading it when no Content-Length is declared" do
      stream = StringIO.new(content)
      allow(stream).to receive(:read).and_call_original
      req = stream_request(stream, content_length: nil)

      captured = Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil)

      expect(stream).not_to have_received(:read)
      expect(captured).to be_a(Coolhand::NetHttpInterceptor::BodyStreamTap)
      expect(req.body_stream).to equal(captured)
      expect(captured.source).to equal(stream)
    end

    it "does not raise on a malformed Content-Length, and taps the stream rather than trusting it" do
      req = stream_request(StringIO.new(content), content_length: "not-a-number")

      captured = Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil)

      expect(captured).to be_a(Coolhand::NetHttpInterceptor::BodyStreamTap)
    end

    it "ignores a Content-Length header on a chunked request, as Net::HTTP does" do
      req = stream_request(StringIO.new(content), content_length: "5")
      req["Transfer-Encoding"] = "chunked"

      expect(Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil))
        .to be_a(Coolhand::NetHttpInterceptor::BodyStreamTap)
    end

    it "does not pre-check when the cap is disabled" do
      Coolhand.configuration.max_captured_body_bytes = nil
      req = stream_request(StringIO.new(content))

      expect(Coolhand::NetHttpInterceptor::Helpers.capture_request_body(req, nil))
        .to eq({ "streamed" => "this payload is well over ten bytes long" })
    end
  end

  describe "response body cap (max_captured_body_bytes)" do
    let(:helpers) { Coolhand::NetHttpInterceptor::Helpers }

    after { Thread.current[:coolhand_stream_buffer] = nil }

    def intercepted_request(request_class, url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.request(request_class.new(uri)).tap { sleep 0.05 }
    end

    it "replaces an oversized non-streamed response body with a marker, but returns it to the host in full" do
      Coolhand.configuration.max_captured_body_bytes = 10
      body = '{"text":"a response that is well over ten bytes long"}'
      stub_request(:post, "https://api.test.com/v1/chat")
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })

      response = intercepted_request(Net::HTTP::Post, "https://api.test.com/v1/chat")

      expect(response.body).to eq(body)
      logged = @captured_log[:raw_request][:response_body]
      expect(logged).to eq(
        "_coolhand_capture_skipped" => "body_too_large",
        "size_bytes" => body.bytesize,
        "max_bytes" => 10,
        "content_type" => "application/json"
      )
    end

    it "logs a non-streamed response body at or under the cap unchanged" do
      Coolhand.configuration.max_captured_body_bytes = 12
      stub_request(:get, "https://api.test.com/hello")
        .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })

      intercepted_request(Net::HTTP::Get, "https://api.test.com/hello")

      expect(@captured_log[:raw_request][:response_body]).to eq({ "msg" => "hi" })
    end

    it "does not cap response bodies when max_captured_body_bytes is nil" do
      Coolhand.configuration.max_captured_body_bytes = nil
      stub_request(:get, "https://api.test.com/hello")
        .to_return(status: 200, body: '{"msg":"hi"}', headers: { "Content-Type" => "application/json" })

      intercepted_request(Net::HTTP::Get, "https://api.test.com/hello")

      expect(@captured_log[:raw_request][:response_body]).to eq({ "msg" => "hi" })
    end

    describe "capture failures never reach the host" do
      it "buffer_stream_chunk logs and swallows an error instead of raising into read_body" do
        expect(Coolhand).to receive(:log).with(a_string_including("Error buffering streamed response chunk"))

        expect { helpers.buffer_stream_chunk(nil) }.not_to raise_error
      end

      it "capture_response logs and returns nils when building the log body raises" do
        response = instance_double(Net::HTTPResponse, code: "200", body: "ok")
        allow(helpers).to receive(:response_body_for_log).and_raise(StandardError, "boom")
        expect(Coolhand).to receive(:log).with(a_string_including("Error capturing response: boom"))

        expect(helpers.capture_response(response)).to eq([nil, nil])
      end
    end

    describe ".buffer_stream_chunk" do
      before { Coolhand.configuration.max_captured_body_bytes = 10 }

      it "accumulates chunks while the total stays within the cap" do
        helpers.buffer_stream_chunk("12345")
        helpers.buffer_stream_chunk("67890")

        expect(Thread.current[:coolhand_stream_buffer]).to eq("1234567890")
      end

      it "drops the buffered content and keeps only a running byte count once the cap is crossed mid-chunk" do
        helpers.buffer_stream_chunk("123456")
        helpers.buffer_stream_chunk("789012")
        expect(Thread.current[:coolhand_stream_buffer]).to eq(12)

        helpers.buffer_stream_chunk("abc")
        expect(Thread.current[:coolhand_stream_buffer]).to eq(15)
      end

      it "keeps a stream that lands exactly on the cap, and trips only on the next byte" do
        helpers.buffer_stream_chunk("1234567890")
        expect(Thread.current[:coolhand_stream_buffer]).to eq("1234567890")

        helpers.buffer_stream_chunk("1")
        expect(Thread.current[:coolhand_stream_buffer]).to eq(11)
      end

      it "buffers without limit when the cap is nil" do
        Coolhand.configuration.max_captured_body_bytes = nil
        helpers.buffer_stream_chunk("x" * 5_000)

        expect(Thread.current[:coolhand_stream_buffer].bytesize).to eq(5_000)
      end

      it "falls back to the default cap instead of raising when the configured cap is not an Integer" do
        Coolhand.configuration.max_captured_body_bytes = "10"

        expect { helpers.buffer_stream_chunk("x" * 50) }.not_to raise_error
        expect(Thread.current[:coolhand_stream_buffer]).to eq("x" * 50)
        expect(helpers.response_body_for_log("x" * 2_000_000, nil)).to include(
          "_coolhand_capture_skipped" => "body_too_large", "max_bytes" => 1_000_000
        )
      end

      it "treats a negative or Float cap as invalid and uses the default" do
        [-1, 10.5].each do |bad|
          Coolhand.configuration.max_captured_body_bytes = bad

          expect(helpers.capture_limit).to eq(Coolhand::Configuration::DEFAULT_MAX_CAPTURED_BODY_BYTES)
        end
      end

      it "treats a cap of 0 as 'capture nothing' and still handles an empty or nil body" do
        Coolhand.configuration.max_captured_body_bytes = 0

        expect(helpers.response_body_for_log(nil, nil)).to be_nil
        expect(helpers.response_body_for_log("", nil)).to eq("")
        expect(helpers.response_body_for_log("x", nil)).to include("_coolhand_capture_skipped" => "body_too_large")
      end

      it "counts bytes, not characters" do
        helpers.buffer_stream_chunk("こんにちは")

        expect(Thread.current[:coolhand_stream_buffer]).to eq(15)
      end
    end

    it "streams an oversized response to the host in full while logging only a marker (over a real connection)" do
      Coolhand.configuration.max_captured_body_bytes = 40
      pieces = Array.new(4) { |i| "piece-#{i}-".ljust(25, "x") }
      body = pieces.join
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server_thread = Thread.new do
        client = server.accept
        client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        client.gets("\r\n\r\n")
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n" \
                     "Connection: close\r\n\r\n")
        pieces.each do |piece|
          client.write("#{piece.bytesize.to_s(16)}\r\n#{piece}\r\n")
          sleep 0.05
        end
        client.write("0\r\n\r\n")
        client.close
      end
      Coolhand.configuration.intercept_addresses = ["127.0.0.1"]

      begin
        WebMock.disable!
        http_class = Class.new(Net::HTTP) { prepend Coolhand::NetHttpInterceptor }
        received = +""
        buffer_states = []
        http_class.start("127.0.0.1", port) do |http|
          http.request(Net::HTTP::Get.new("/stream")) do |res|
            res.read_body do |chunk|
              received << chunk
              buffer_states << Thread.current[:coolhand_stream_buffer].dup
            end
          end
        end

        raw = @captured_log[:raw_request]
        expect(received).to eq(body)
        # First 25-byte piece is within the 40-byte cap and buffered; once the second crosses it the
        # buffer is dropped for a running byte count and never holds more than the cap again.
        expect(buffer_states.first).to be_a(String).and(satisfy { |s| s.bytesize <= 40 })
        expect(buffer_states.last).to eq(body.bytesize)
        expect(buffer_states.grep(String).map(&:bytesize).max).to be <= 40
        expect(raw[:is_streaming]).to be true
        expect(raw[:response_body]).to include(
          "_coolhand_capture_skipped" => "body_too_large", "size_bytes" => body.bytesize, "max_bytes" => 40
        )
        expect(Thread.current[:coolhand_stream_buffer]).to be_nil
        expect(Thread.current[:coolhand_capturing_stream]).to be_nil
      ensure
        WebMock.enable!
        server_thread.kill
        server.close
      end
    end
  end

  it "does not buffer a streamed read_body for a request that was never intercepted" do
    stub_request(:get, "https://not-intercepted.example.com/stream")
      .to_return(status: 200, body: "chunk1chunk2")

    Thread.current[:coolhand_stream_buffer] = nil

    uri = URI("https://not-intercepted.example.com/stream")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri)

    http.request(req) do |res|
      res.read_body { |_chunk| nil }
    end

    expect(Thread.current[:coolhand_stream_buffer]).to be_nil
  end

  it "restores the enclosing request's stream buffer (rather than clobbering it) after a nested " \
     "intercepted request completes inside a callback" do
    stub_request(:get, "https://api.test.com/inner").to_return(status: 200, body: "inner-body")

    # Simulate being in the middle of an outer request's streaming capture:
    # some chunks already buffered, capturing flag on. A real nested call
    # (e.g. a second LLM call made from inside a chunk-processing callback)
    # must not permanently wipe this out for the outer request.
    Thread.current[:coolhand_stream_buffer] = "OUTER-PARTIAL-CHUNKS-SO-FAR"
    Thread.current[:coolhand_capturing_stream] = true

    begin
      uri = URI("https://api.test.com/inner")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.request(Net::HTTP::Get.new(uri))
      sleep 0.05

      expect(Thread.current[:coolhand_stream_buffer]).to eq("OUTER-PARTIAL-CHUNKS-SO-FAR")
    ensure
      Thread.current[:coolhand_stream_buffer] = nil
      Thread.current[:coolhand_capturing_stream] = nil
    end
  end

  it "still logs when the HTTP call raises an exception (e.g. SDK error on 4xx)" do
    stub_request(:post, "https://api.test.com/v1/messages")
      .to_return(
        status: 404,
        body: '{"type":"error","error":{"type":"not_found_error","message":"model: claude-3-7-sonnet-latest"}}',
        headers: { "Content-Type" => "application/json" }
      )

    uri = URI("https://api.test.com/v1/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body = '{"model":"claude-3-7-sonnet-latest"}'

    response = http.request(req)
    expect(response.code.to_i).to eq(404)

    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw[:status_code] || raw["status_code"]).to eq(404)
  end

  describe "exclude_api_patterns" do
    before(:each) do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = ["aiplatform.googleapis.com"]
      end
    end

    def make_request(path_and_query)
      stub_request(:get, "https://aiplatform.googleapis.com#{path_and_query}")
        .to_return(status: 200, body: '{"status":"ok"}', headers: { "Content-Type" => "application/json" })

      uri = URI("https://aiplatform.googleapis.com#{path_and_query}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      http.request(req)
      sleep 0.05
    end

    it "does not capture URLs matching the default /batchPredictionJobs/ pattern" do
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
      expect(@captured_log).to be_nil
    end

    it "still captures a request when the exclude pattern only appears in the query string, not the path" do
      make_request("/v1/projects/my-project/locations/us-central1/models?x=/batchPredictionJobs/")
      expect(@captured_log).to be_a(Hash)
    end

    it "captures URLs that do not match any exclude pattern" do
      make_request("/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-pro:generateContent")
      expect(@captured_log).to be_a(Hash)
    end

    it "captures all URLs when exclude_api_patterns is set to empty" do
      Coolhand.configuration.exclude_api_patterns = []
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
      expect(@captured_log).to be_a(Hash)
    end

    it "excludes URLs matching a custom pattern appended with <<" do
      Coolhand.configuration.exclude_api_patterns << ":generateContent"
      make_request("/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-pro:generateContent")
      expect(@captured_log).to be_nil
    end

    it "excludes only patterns in the overridden list when using =" do
      Coolhand.configuration.exclude_api_patterns = ["/generateContent"]
      # batchPredictionJobs is no longer excluded
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
      expect(@captured_log).to be_a(Hash)
    end

    it "logs a debug message when a URL is excluded and debug_mode is enabled" do
      Coolhand.configuration.debug_mode = true
      expect(Coolhand).to receive(:log).with(/Skipping capture.*batchPredictionJobs/)
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
    end

    it "does not log a debug message for excluded URLs when debug_mode is disabled" do
      expect(Coolhand).not_to receive(:log).with(/Skipping capture/)
      make_request("/v1/projects/my-project/locations/us-central1/batchPredictionJobs/123")
    end

    it "sanitizes the URL in the debug skip message so query-param secrets aren't logged raw" do
      Coolhand.configuration.debug_mode = true
      Coolhand.configuration.exclude_api_patterns << ":generateContent"
      expect(Coolhand).to receive(:log) do |message|
        expect(message).to include("REDACTED")
        expect(message).not_to include("AIzaSyDEADBEEF1234567890")
      end
      make_request("/v1/models/gemini-pro:generateContent?key=AIzaSyDEADBEEF1234567890")
    end

    it "exposes DEFAULT_EXCLUDE_API_PATTERNS as a frozen constant" do
      defaults = Coolhand::Configuration::DEFAULT_EXCLUDE_API_PATTERNS
      expect(defaults).to include("/batchPredictionJobs/")
      expect(defaults).to be_frozen
    end

    it "initializes exclude_api_patterns as a mutable copy of the defaults" do
      patterns = Coolhand.configuration.exclude_api_patterns
      expect(patterns).to include("/batchPredictionJobs/")
      expect(patterns).not_to be_frozen
    end

    it "excludes Azure OpenAI control-plane paths by default (issue #114)" do
      %w[/openai/files /openai/batches /openai/fine_tuning /openai/models
         /openai/v1/files /openai/v1/batches /openai/v1/fine_tuning /openai/v1/models].each do |path|
        make_request(path)
        expect(@captured_log).to be_nil
      end
    end

    it "does not let the /openai/files exclusion accidentally match /openai/v1/files (contiguous substring match)" do
      # Only the unversioned pattern is present; the /v1/ path must still be captured.
      Coolhand.configuration.exclude_api_patterns = ["/openai/files"]
      make_request("/openai/v1/files")
      expect(@captured_log).to be_a(Hash)
    end
  end

  describe "Gemini API interception" do
    before do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = ["generativelanguage.googleapis.com"]
      end
    end

    it "intercepts Gemini generateContent requests by domain" do
      stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent")
        .to_return(status: 200, body: '{"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}',
          headers: { "Content-Type" => "application/json" })

      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req.body = '{"contents":[{"parts":[{"text":"Hi"}]}]}'
      req["Content-Type"] = "application/json"

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      expect(raw[:url] || raw["url"]).to include("generativelanguage.googleapis.com")
      expect(raw[:url] || raw["url"]).to include(":generateContent")
    end

    it "intercepts Gemini streamGenerateContent requests" do
      stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:streamGenerateContent?alt=sse")
        .to_return(status: 200, body: '{"candidates":[]}',
          headers: { "Content-Type" => "application/json" })

      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:streamGenerateContent?alt=sse")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req.body = '{"contents":[{"parts":[{"text":"Hi"}]}]}'
      req["Content-Type"] = "application/json"

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      expect(raw[:url] || raw["url"]).to include(":streamGenerateContent")
    end

    it "sanitizes x-goog-api-key header" do
      stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent")
        .to_return(status: 200, body: '{"candidates":[]}',
          headers: { "Content-Type" => "application/json" })

      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req["x-goog-api-key"] = "AIzaSyDEADBEEF1234567890"
      req["Content-Type"] = "application/json"
      req.body = '{"contents":[]}'

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      headers = raw[:headers] || raw["headers"]
      goog_key = headers["x-goog-api-key"] || headers["X-Goog-Api-Key"]
      expect(goog_key).to eq("[REDACTED]")
    end

    it "sanitizes an Authorization Bearer header, preserving the 'Bearer' prefix as a marker" do
      Coolhand.configuration.intercept_addresses << "authtest.example.com"
      stub_request(:post, "https://authtest.example.com/v1/chat/completions")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      uri = URI("https://authtest.example.com/v1/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer sk-DEADBEEF1234567890"
      req["Content-Type"] = "application/json"
      req.body = "{}"

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      headers = raw[:headers] || raw["headers"]
      auth = headers["Authorization"] || headers["authorization"]
      expect(auth).to eq("Bearer [REDACTED]")
    end

    it "fully redacts a non-Bearer Authorization header (e.g. AWS SigV4)" do
      Coolhand.configuration.intercept_addresses << "authtest.example.com"
      stub_request(:post, "https://authtest.example.com/v1/chat/completions")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      uri = URI("https://authtest.example.com/v1/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "AWS4-HMAC-SHA256 Credential=AKIADEADBEEF/20260730/us-east-1/bedrock/aws4_request"
      req["Content-Type"] = "application/json"
      req.body = "{}"

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      headers = raw[:headers] || raw["headers"]
      auth = headers["Authorization"] || headers["authorization"]
      expect(auth).to eq("[REDACTED]")
    end

    it "sanitizes x-amz-security-token header (AWS Bedrock STS session token)" do
      Coolhand.configuration.intercept_addresses << "bedrock-runtime.*.amazonaws.com"
      stub_request(:post, "https://bedrock-runtime.us-east-1.amazonaws.com/model/foo/invoke")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      uri = URI("https://bedrock-runtime.us-east-1.amazonaws.com/model/foo/invoke")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req["x-amz-security-token"] = "FQoGZXIvYXdzEDEaDBEEF1234567890SESSIONTOKEN"
      req["Content-Type"] = "application/json"
      req.body = "{}"

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      headers = raw[:headers] || raw["headers"]
      token = headers["x-amz-security-token"] || headers["X-Amz-Security-Token"]
      expect(token).to eq("[REDACTED]")
    end

    it "sanitizes key query parameter from URL" do
      stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=AIzaSyDEADBEEF1234567890")
        .to_return(status: 200, body: '{"candidates":[]}',
          headers: { "Content-Type" => "application/json" })

      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=AIzaSyDEADBEEF1234567890")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = '{"contents":[]}'

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_a(Hash)
      raw = @captured_log[:raw_request] || @captured_log["raw_request"]
      url = raw[:url] || raw["url"]
      expect(url).not_to include("AIzaSyDEADBEEF1234567890")
      expect(url).to include("REDACTED")
    end

    it "does not intercept an unrelated host just because a Gemini-style path token appears in its path" do
      stub_request(:post, "https://attacker.tld/v1/models/gemini-pro:generateContent")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      uri = URI("https://attacker.tld/v1/models/gemini-pro:generateContent")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = "{}"

      http.request(req)
      sleep 0.05

      expect(@captured_log).to be_nil
    end
  end

  describe "issue #85 — host-boundary matching" do
    let(:interceptor) { Coolhand::NetHttpInterceptor::Helpers }

    before do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES.dup
      end
    end

    it "does not intercept a redirect URL that merely mentions a real host in its query string" do
      expect(interceptor.intercept?("https://evil.com/redirect?to=api.openai.com")).to be false
    end

    it "does not intercept a host that merely has a real host as a prefix (suffix confusion)" do
      expect(interceptor.intercept?("https://api.openai.com.attacker.net/v1/chat/completions")).to be false
    end

    it "does not intercept an unrelated host just because a bare Gemini path token appears in its path" do
      expect(interceptor.intercept?("https://attacker.tld/:generateContent")).to be false
    end

    it "intercepts the real host regardless of case" do
      expect(interceptor.intercept?("https://API.OPENAI.COM/v1/chat/completions")).to be true
    end

    it "fails closed (does not intercept, does not raise) for an unparseable URL" do
      expect(interceptor.intercept?("https://api.openai.com:notaport/v1/chat/completions")).to be false
    end

    it "matches a wildcard host entry against exactly one label" do
      expect(interceptor.host_matches?("bedrock-runtime.us-east-1.amazonaws.com",
        "bedrock-runtime.*.amazonaws.com")).to be true
      expect(interceptor.host_matches?("bedrock-runtime.amazonaws.com",
        "bedrock-runtime.*.amazonaws.com")).to be false
      expect(interceptor.host_matches?("bedrock-runtime.us-east-1.evil.com",
        "bedrock-runtime.*.amazonaws.com")).to be false
    end

    it "does not fall back to intercept_path_patterns for googleapis.com hosts when intercept_addresses " \
       "has been overridden to exclude all Google hosts" do
      Coolhand.configuration.intercept_addresses = ["only.mycompany.internal"]

      expect(interceptor.intercept?(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent"
      )).to be false
    end

    it "falls back to intercept_path_patterns for a googleapis.com host not explicitly listed, as long as " \
       "intercept_addresses still includes a Google host" do
      expect(interceptor.intercept?(
        "https://some-other-service.googleapis.com/v1/models/gemini-pro:generateContent"
      )).to be true
    end

    it "does not treat a lookalike host (e.g. evilgoogleapis.com) as a configured Google host" do
      Coolhand.configuration.intercept_addresses = ["evilgoogleapis.com"]

      expect(interceptor.intercept?(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent"
      )).to be false
    end

    it "exposes DEFAULT_INTERCEPT_PATH_PATTERNS as a frozen constant" do
      defaults = Coolhand::Configuration::DEFAULT_INTERCEPT_PATH_PATTERNS
      expect(defaults).to include(":generateContent", ":streamGenerateContent")
      expect(defaults).to be_frozen
    end
  end

  describe "issue #114 — Azure host+path-anchored intercept addresses" do
    let(:interceptor) { Coolhand::NetHttpInterceptor::Helpers }

    before do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES.dup
      end
    end

    it "intercepts a path-anchored Azure AI Services host on its /openai/ path" do
      expect(interceptor.intercept?(
        "https://myresource.cognitiveservices.azure.com/openai/deployments/x/chat/completions"
      )).to be true
    end

    it "does not intercept the same Azure AI Services host on an unrelated (Speech/Vision/Language) path" do
      expect(interceptor.intercept?(
        "https://myresource.cognitiveservices.azure.com/language/analyze-text"
      )).to be false
    end

    it "intercepts a path-anchored Azure AI Foundry host on its /models/ path" do
      expect(interceptor.intercept?(
        "https://myresource.services.ai.azure.com/models/chat/completions"
      )).to be true
    end

    it "intercepts the unanchored inference.ml.azure.com host regardless of path" do
      expect(interceptor.intercept?("https://myendpoint.inference.ml.azure.com/score")).to be true
      expect(interceptor.intercept?("https://myendpoint.inference.ml.azure.com/anything-else")).to be true
    end

    it "matches address_matches? for a bare host pattern the same way host_matches? would" do
      expect(interceptor.address_matches?("openai.azure.com", "/openai/deployments/x",
        "openai.azure.com")).to be true
      expect(interceptor.address_matches?("evil.com", "/openai/deployments/x",
        "openai.azure.com")).to be false
    end

    it "requires both host and path prefix to match for a path-anchored pattern" do
      expect(interceptor.address_matches?("myresource.cognitiveservices.azure.com", "/openai/chat",
        "cognitiveservices.azure.com/openai/")).to be true
      expect(interceptor.address_matches?("myresource.cognitiveservices.azure.com", "/vision/analyze",
        "cognitiveservices.azure.com/openai/")).to be false
      expect(interceptor.address_matches?("evil.com", "/openai/chat",
        "cognitiveservices.azure.com/openai/")).to be false
    end

    it "matches on a path-segment boundary even when the pattern has no trailing slash" do
      # A custom entry without a trailing slash must not prefix-collide with an unrelated
      # same-prefix segment (e.g. "/openai" vs "/openaiz").
      expect(interceptor.address_matches?("host.com", "/openai", "host.com/openai")).to be true
      expect(interceptor.address_matches?("host.com", "/openai/chat", "host.com/openai")).to be true
      expect(interceptor.address_matches?("host.com", "/openaiz/chat", "host.com/openai")).to be false
    end

    it "matches every path under the host when the pattern's path segment is empty" do
      expect(interceptor.address_matches?("host.com", "/anything", "host.com/")).to be true
      expect(interceptor.address_matches?("host.com", "/", "host.com/")).to be true
    end

    it "treats the path anchor as case-sensitive" do
      expect(interceptor.address_matches?("host.com", "/OpenAI/chat", "host.com/openai/")).to be false
    end
  end

  it "logs with extracted status and SDK exception format when super itself raises" do
    stub_request(:post, "https://api.test.com/v1/messages")
      .to_raise(RuntimeError.new("status: 404, body: not_found_error"))

    uri = URI("https://api.test.com/v1/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri)
    req.body = '{"model":"claude-3-7-sonnet-latest"}'

    expect { http.request(req) }.to raise_error(RuntimeError)

    sleep 0.05

    expect(@captured_log).to be_a(Hash)
    raw = @captured_log[:raw_request] || @captured_log["raw_request"]
    expect(raw[:status_code] || raw["status_code"]).to eq(404)
    resp_body = raw[:response_body] || raw["response_body"]
    expect(resp_body).to be_a(Hash)
    error_info = resp_body["error"] || resp_body[:error]
    expect(error_info["class"]).to include("RuntimeError")
  end
end
