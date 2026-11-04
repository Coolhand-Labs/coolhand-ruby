# frozen_string_literal: true

# Smoke test for abandoned streamed responses: a stream the host stops reading before it ends must
# be logged with `raw_request.stream_incomplete: true` and the partial body; a stream read to its
# end must not carry the field.
# Run: bundle exec ruby examples/abandoned_stream_example.rb
# Optional env: COOLHAND_API_KEY plus OPENAI_API_KEY and/or ANTHROPIC_API_KEY (live scenario)
#
# Scenario 1 (local, always runs): a fake streaming LLM server and a fake Coolhand server. Free,
#   deterministic, needs no keys. Asserts the logged payload for each way a host can leave a stream.
# Scenario 2 (live, needs COOLHAND_API_KEY plus a provider key): a real streamed provider call that
#   the host abandons after its first chunk, sent to the real Coolhand API. Asserts the log carries
#   the marker and was delivered.
#
# Exits non-zero if an assertion fails.

require "socket"
require "json"
require "net/http"
require "coolhand"
require_relative "support/http_helpers"

$stdout.sync = true
@failures = []

# Records every payload ApiService is asked to send and whether the POST succeeded (a nil result
# means it failed; Coolhand's own "Sent" log line is printed either way, so it can't prove delivery).
module PayloadSpy
  Sent = Struct.new(:raw_request, :delivered)

  class << self
    def sent = @sent ||= []

    def reset! = @sent = []
  end

  def send_llm_request_log(request_data)
    super.tap { |result| PayloadSpy.sent << PayloadSpy::Sent.new(request_data[:raw_request], !result.nil?) }
  end
end
Coolhand::ApiService.prepend(PayloadSpy)

SSE_EVENTS = [
  %(data: {"choices":[{"delta":{"content":"one"}}]}\n\n),
  %(data: {"choices":[{"delta":{"content":"two"}}]}\n\n),
  %(data: {"choices":[{"delta":{"content":"three"}}]}\n\n),
  %(data: [DONE]\n\n)
].freeze

def write_chunk(socket, data) = socket.write("#{data.bytesize.to_s(16)}\r\n#{data}\r\n")

# Accepts connections on `server`, one thread each. Reads the request, then hands the socket to the block.
def serve(server)
  Thread.new do
    loop do
      Thread.new(server.accept) do |socket|
        read_http_request(socket)
        yield socket
      rescue StandardError
        nil # the host hung up mid-response
      ensure
        socket.close
      end
    end
  end
end

# Fake LLM: streams SSE_EVENTS as separate chunks, a beat apart, so the host can stop part-way.
def serve_stream(server)
  serve(server) do |socket|
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    SSE_EVENTS.each do |event|
      write_chunk(socket, event)
      sleep 0.05
    end
    socket.write("0\r\n\r\n")
  end
end

def serve_coolhand(server)
  serve(server) do |socket|
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: 8\r\nConnection: close\r\n\r\n{\"id\":1}")
  end
end

def stream_request(uri, &block)
  request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  request.body = { model: "fake", stream: true, messages: [] }.to_json
  Net::HTTP.start(uri.host, uri.port) { |http| http.request(request, &block) }
end

# One streamed call; returns the single payload it logged. `throw :abandon` unwinds out of the whole
# request, as a consumer that stops reading would.
def logged_payload_for(uri, &host_behaviour)
  PayloadSpy.reset!
  begin
    catch(:abandon) { stream_request(uri, &host_behaviour) }
  rescue StandardError
    nil # the host's own raise is part of the scenario
  end
  Coolhand.flush(timeout: 10)
  PayloadSpy.sent.last
end

def marked?(sent) = sent&.raw_request&.fetch(:stream_incomplete, nil) == true

def unmarked?(sent) = !sent.nil? && !sent.raw_request.key?(:stream_incomplete)

def body_includes?(sent, text) = sent&.raw_request&.fetch(:response_body, nil).to_s.include?(text)

def start_local_servers
  llm = TCPServer.new("127.0.0.1", 0)
  coolhand = TCPServer.new("127.0.0.1", 0)
  serve_stream(llm)
  serve_coolhand(coolhand)

  Coolhand.reset_configuration!
  Coolhand.configure do |c|
    c.api_key = "abandoned-stream-key"
    c.silent = true
    c.async_logging = false
    c.base_url = "http://127.0.0.1:#{coolhand.addr[1]}/api"
    c.intercept_addresses = ["127.0.0.1:#{llm.addr[1]}"]
  end
  URI("http://127.0.0.1:#{llm.addr[1]}/v1/chat/completions")
end

def check_read_to_end(uri)
  sent = logged_payload_for(uri) { |res| res.read_body { |_chunk| nil } }
  check("a stream read to its end omits stream_incomplete, body complete",
    unmarked?(sent) && body_includes?(sent, "[DONE]"))
end

def check_break(uri)
  sent = logged_payload_for(uri) { |res| res.read_body { |chunk| break if chunk.include?("one") } }
  check("break after the first chunk: marked, with the partial body",
    marked?(sent) && body_includes?(sent, "one"))
  check("break after the first chunk: one record, delivered", PayloadSpy.sent.size == 1 && sent.delivered)
end

def check_throw(uri)
  sent = logged_payload_for(uri) { |res| res.read_body { |chunk| throw :abandon if chunk.include?("one") } }
  check("throw out of the request: marked, stream cut short", marked?(sent) && !body_includes?(sent, "[DONE]"))
end

def check_host_raise(uri)
  sent = logged_payload_for(uri) { |res| res.read_body { |chunk| raise "host failure" if chunk.include?("one") } }
  check("host raise mid-stream: marked, host message not logged",
    marked?(sent) && !JSON.generate(sent.raw_request).include?("host failure"))
end

def check_not_streamed(uri)
  sent = logged_payload_for(uri) { |res| res.read_body.to_s }
  check("non-streaming read of the same response omits stream_incomplete", unmarked?(sent))
end

def run_local_scenario
  puts "\n=== Scenario 1: local fake streaming LLM + fake Coolhand ==="
  uri = start_local_servers
  check_read_to_end(uri)
  check_break(uri)
  check_throw(uri)
  check_host_raise(uri)
  check_not_streamed(uri)
end

LIVE_PROVIDERS = {
  "openai" => {
    env: "OPENAI_API_KEY",
    uri: "https://api.openai.com/v1/chat/completions",
    headers: ->(key) { { "Authorization" => "Bearer #{key}" } },
    body: { model: "gpt-4o-mini", stream: true, max_tokens: 64,
            messages: [{ role: "user", content: "Count from one to ten in words." }] }
  },
  "anthropic" => {
    env: "ANTHROPIC_API_KEY",
    uri: "https://api.anthropic.com/v1/messages",
    headers: ->(key) { { "x-api-key" => key, "anthropic-version" => "2023-06-01" } },
    body: { model: "claude-haiku-4-5", stream: true, max_tokens: 64,
            messages: [{ role: "user", content: "Count from one to ten in words." }] }
  }
}.freeze

def live_request(provider)
  uri = URI(provider[:uri])
  headers = { "Content-Type" => "application/json" }.merge(provider[:headers].call(ENV.fetch(provider[:env])))
  request = Net::HTTP::Post.new(uri, headers)
  request.body = provider[:body].to_json
  [uri, request]
end

# `throw` unwinds out of the request, so Net::HTTP.start closes the connection, as a consumer that
# stops reading a live stream would. A bare `break` out of read_body would leave Net::HTTP to drain a
# half-read chunk on a still-open socket until it times out, which is Net::HTTP's behaviour, not a
# stream that was abandoned.
def abandon_live_stream(provider)
  uri, request = live_request(provider)
  catch(:abandon) do
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) do |http|
      http.request(request) { |response| throw_on_first_event(response) }
    end
  end
end

def throw_on_first_event(response)
  raise "provider returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.read_body { |chunk| throw :abandon if chunk.include?("data:") }
end

def check_live_provider(name, provider)
  PayloadSpy.reset!
  abandon_live_stream(provider)
  Coolhand.flush(timeout: 30)
  sent = PayloadSpy.sent.last
  check("#{name}: one record, marked stream_incomplete, partial body kept, delivered",
    PayloadSpy.sent.size == 1 && marked?(sent) && body_includes?(sent, "data:") && sent.delivered)
end

def run_live_scenario
  providers = LIVE_PROVIDERS.select { |_, p| ENV.fetch(p[:env], nil) }
  if ENV["COOLHAND_API_KEY"].nil? || providers.empty?
    puts "\nSkipping live scenario — needs COOLHAND_API_KEY plus OPENAI_API_KEY and/or ANTHROPIC_API_KEY."
    return
  end

  puts "\n=== Scenario 2: live provider stream, abandoned after the first chunk ==="
  Coolhand.reset_configuration!
  Coolhand.configure do |c|
    c.api_key = ENV.fetch("COOLHAND_API_KEY")
    c.silent = false
    c.async_logging = false
  end

  providers.each { |name, provider| check_live_provider(name, provider) }
end

run_local_scenario
run_live_scenario

if @failures.empty?
  puts "\nAbandoned-stream smoke test passed."
else
  puts "\n#{@failures.size} check(s) failed:"
  @failures.each { |failure| puts "  - #{failure}" }
  exit 1
end
