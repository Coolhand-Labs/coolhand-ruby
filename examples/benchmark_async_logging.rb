# frozen_string_literal: true

# Benchmark + regression check for async logging (issue #126): how much latency does
# Coolhand add to an intercepted LLM call, and does a slow Coolhand backend leak into it?
# Run: bundle exec ruby examples/benchmark_async_logging.rb
# Optional env: N (calls per mode, default 8), COOLHAND_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY
#
# Scenario 1 (local, always runs): a fake LLM server and a fake Coolhand server that takes 2s to
#   reply. Deterministic, free, needs no keys. Proves the intercepted call isn't held up by a
#   slow Coolhand and that every log is still delivered.
# Scenario 2 (live, needs COOLHAND_API_KEY plus a provider key): real provider calls against the
#   real Coolhand API. Reports overhead per provider and checks that every log was delivered.
#   Provider latency is noisy, so its overhead bound is deliberately loose.
#
# Exits non-zero if an assertion fails. Modes are interleaved per iteration so drift in provider
# latency affects all three equally.

require "socket"
require "json"
require "net/http"
require "coolhand"

N = Integer(ENV.fetch("N", "8"), exception: false)
abort("N must be an integer between 1 and 1000") unless N&.between?(1, 1000)
SLOW_COOLHAND_DELAY = 2.0
# Async must add at most this much over baseline. The local scenario is quiet enough to compare
# medians with a tight bound. Live provider latency swings by hundreds of ms between identical
# calls, so the live check compares the *fastest* call per mode (the latency floor, which jitter
# can't inflate): an inline Coolhand POST raises that floor by its full round-trip, async doesn't.
LOCAL_ASYNC_BUDGET_MS = 250
LIVE_ASYNC_BUDGET_MS = 200
# NOTE: the live check can only catch an inline-POST regression that costs more than the budget, so
# treat it as a smoke test against real APIs; the local scenario is the sensitive regression guard.

$stdout.sync = true
@failures = []

def check(description, passed)
  puts "  #{passed ? 'PASS' : 'FAIL'}  #{description}"
  @failures << description unless passed
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def median(values) = values.sort[values.size / 2]

def ms(seconds) = (seconds * 1000).round

# Signed milliseconds for overhead figures, so a negative value reads "-12ms" rather than "+-12ms".
def signed(milliseconds)
  format("%<sign>s%<value>d", sign: milliseconds.negative? ? "-" : "+",
    value: milliseconds.abs)
end

# Counts what ApiService actually got back from the Coolhand API. A nil result means the POST
# failed (timeout, non-2xx, ...) — Coolhand's own "Sent" log line is printed either way, so it
# can't be used to prove delivery. Works across threads, so it sees async sends too.
class DeliveryCounter
  attr_reader :delivered, :failed

  def initialize
    @delivered = 0
    @failed = 0
    @mutex = Mutex.new
  end

  def record(result)
    @mutex.synchronize { result ? @delivered += 1 : @failed += 1 }
  end

  def total = @delivered + @failed
end

module DeliveryTracking
  class << self
    attr_accessor :counter
  end

  def send_llm_request_log(request_data)
    super.tap { |result| DeliveryTracking.counter&.record(result) }
  end
end
Coolhand::ApiService.prepend(DeliveryTracking)

def count_deliveries
  DeliveryTracking.counter = DeliveryCounter.new
  yield DeliveryTracking.counter
ensure
  DeliveryTracking.counter = nil
end

MODES = {
  "baseline (capture off)" => ->(config) { config.capture = false },
  "sync (async_logging=false)" => lambda { |config|
    config.capture = true
    config.async_logging = false
  },
  "async (async_logging=true)" => lambda { |config|
    config.capture = true
    config.async_logging = true
  }
}.freeze

# Runs `call` N times per mode, interleaved. Returns { mode => [seconds, ...] }.
def measure(call)
  # Warm-up (DNS/TLS/connection), unmeasured. It is captured, so start from a known mode rather
  # than whatever a previously failed provider left behind.
  Coolhand.configuration.capture = true
  Coolhand.configuration.async_logging = true
  call.call
  Coolhand.flush(timeout: 30)
  times = MODES.keys.to_h { |name| [name, []] }
  N.times do
    MODES.each do |name, setup|
      setup.call(Coolhand.configuration)
      started = now
      call.call
      times[name] << (now - started)
    end
  end
  times
end

def report(title, times, flush_seconds)
  puts "\n#{title} (N=#{N}, interleaved)"
  puts "  #{'mode'.ljust(28)} #{%w[mean median min max].map { |h| h.rjust(8) }.join(' ')}"
  times.each do |name, values|
    cells = [values.sum / values.size, median(values), values.min, values.max].map { |v| "#{ms(v)}ms".rjust(8) }
    puts "  #{name.ljust(28)} #{cells.join(' ')}"
  end
  puts "  trailing Coolhand.flush: #{ms(flush_seconds)}ms"
end

def serve(server, delay: 0)
  Thread.new do
    loop do
      client = server.accept
      Thread.new(client) do |socket|
        head = +""
        head << socket.readpartial(65_536) until head.include?("\r\n\r\n")
        length = head[/content-length:\s*(\d+)/i, 1].to_i
        body = head.split("\r\n\r\n", 2)[1].to_s
        body << socket.readpartial(length - body.bytesize) while body.bytesize < length
        sleep delay
        response = yield(body)
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
      rescue StandardError
        nil
      ensure
        socket.close
      end
    end
  end
end

def verify_no_method_pollution
  puts "\nNet::HTTP method pollution"
  leaked = %i[parse_json sanitize_url sanitize_headers intercept? send_complete_request_log capturable_url]
  Coolhand::NetHttpInterceptor.patch!
  http = Net::HTTP.new("example.com", 443)
  check("Net::HTTP gains no generically named Coolhand helpers",
    leaked.none? { |name| http.respond_to?(name, true) })
ensure
  Coolhand::NetHttpInterceptor.unpatch!
end

def run_local_scenario
  puts "\n=== Scenario 1: local fake LLM + slow (#{SLOW_COOLHAND_DELAY}s) fake Coolhand ==="
  llm = TCPServer.new("127.0.0.1", 0)
  coolhand = TCPServer.new("127.0.0.1", 0)
  received = Queue.new
  serve(llm) { |_body| { choices: [{ message: { content: "ok" } }] }.to_json }
  serve(coolhand, delay: SLOW_COOLHAND_DELAY) do |body|
    received << body
    { id: 1 }.to_json
  end

  Coolhand.reset_configuration!
  Coolhand.configure do |c|
    c.api_key = "benchmark-key"
    c.silent = true
    c.base_url = "http://127.0.0.1:#{coolhand.addr[1]}/api"
    c.intercept_addresses = ["127.0.0.1:#{llm.addr[1]}"]
  end

  uri = URI("http://127.0.0.1:#{llm.addr[1]}/v1/chat/completions")
  call = -> { Net::HTTP.post(uri, { model: "fake", messages: [] }.to_json, "Content-Type" => "application/json") }

  count_deliveries do |counter|
    times = measure(call)
    started = now
    drained = Coolhand.flush(timeout: 60)
    report("Local, slow Coolhand", times, now - started)

    baseline = median(times["baseline (capture off)"])
    sync = median(times["sync (async_logging=false)"])
    async = median(times["async (async_logging=true)"])
    expected = 1 + (2 * N) # warm-up + sync + async calls are captured; baseline is not
    puts
    check("sync mode pays for the slow Coolhand (>= #{ms(SLOW_COOLHAND_DELAY * 0.9)}ms over baseline)",
      ms(sync - baseline) >= ms(SLOW_COOLHAND_DELAY * 0.9))
    check("async adds <= #{LOCAL_ASYNC_BUDGET_MS}ms over baseline (was #{signed(ms(async - baseline))}ms)",
      ms(async - baseline) <= LOCAL_ASYNC_BUDGET_MS)
    check("flush drained the queue", drained)
    check("all #{expected} captured calls delivered (#{counter.delivered} ok, #{counter.failed} failed, " \
          "server saw #{received.size})",
      counter.delivered == expected && counter.failed.zero? && received.size == expected)
  end
end

def live_providers
  providers = {}
  if ENV["OPENAI_API_KEY"]
    require "openai"
    openai = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))
    providers["openai"] = lambda do
      openai.chat(parameters: { model: "gpt-3.5-turbo", max_tokens: 8,
                                messages: [{ role: "user", content: "Reply with one word." }] })
    end
  end
  if ENV["ANTHROPIC_API_KEY"]
    require "anthropic"
    anthropic = Anthropic::Client.new(access_token: ENV.fetch("ANTHROPIC_API_KEY"))
    providers["anthropic"] = lambda do
      anthropic.messages(parameters: { model: "claude-haiku-4-5-20251001", max_tokens: 8,
                                       messages: [{ role: "user", content: "Reply with one word." }] })
    end
  end
  providers
end

def run_live_scenario
  puts "\n=== Scenario 2: live provider calls, live Coolhand ==="
  unless ENV["COOLHAND_API_KEY"]
    puts "Skipping live scenario — COOLHAND_API_KEY not set."
    return
  end
  providers = live_providers
  if providers.empty?
    puts "Skipping live scenario — neither OPENAI_API_KEY nor ANTHROPIC_API_KEY is set."
    return
  end

  Coolhand.reset_configuration!
  Coolhand.configure do |c|
    c.api_key = ENV.fetch("COOLHAND_API_KEY")
    c.silent = true
  end

  providers.each do |name, call|
    count_deliveries do |counter|
      times = begin
        measure(call)
      rescue StandardError => e
        check("#{name}: provider calls succeeded (#{e.class}: #{e.message.lines.first&.strip})", false)
        Coolhand.flush(timeout: 30) # don't let this provider's in-flight logs land in the next one's counter
        next
      end
      started = now
      drained = Coolhand.flush(timeout: 60)
      report("Live #{name}", times, now - started)

      baseline = median(times["baseline (capture off)"])
      sync = median(times["sync (async_logging=false)"])
      async = median(times["async (async_logging=true)"])
      expected = 1 + (2 * N)
      floor = ->(mode) { times[mode].min }
      baseline_floor = floor["baseline (capture off)"]
      sync_floor = ms(floor["sync (async_logging=false)"] - baseline_floor)
      async_floor = ms(floor["async (async_logging=true)"] - baseline_floor)
      puts "  overhead vs baseline — median: sync #{signed(ms(sync - baseline))}ms, " \
           "async #{signed(ms(async - baseline))}ms; " \
           "fastest call: sync #{signed(sync_floor)}ms, async #{signed(async_floor)}ms"
      check("#{name}: async adds <= #{LIVE_ASYNC_BUDGET_MS}ms over baseline " \
            "(fastest call; was #{signed(async_floor)}ms)",
        async_floor <= LIVE_ASYNC_BUDGET_MS)
      check("#{name}: flush drained the queue", drained)
      check("#{name}: all #{expected} captured calls delivered (#{counter.delivered} ok, #{counter.failed} failed)",
        counter.delivered == expected && counter.failed.zero?)
    end
  end
end

run_local_scenario
run_live_scenario
verify_no_method_pollution

puts
if @failures.empty?
  puts "Benchmark passed."
else
  puts "Benchmark FAILED (#{@failures.size}):"
  @failures.each { |failure| puts "  - #{failure}" }
  exit 1
end
