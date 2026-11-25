# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"
require "timeout"

RSpec.describe Coolhand::LogQueue do
  before do
    Coolhand.configuration.silent = true
    Coolhand.configuration.async_logging = true
  end

  def wait_until(timeout: 2)
    Timeout.timeout(timeout) { sleep 0.01 until yield }
  end

  describe ".submit" do
    it "runs the job on a background thread and returns immediately" do
      release = Queue.new
      ran_on = nil

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.submit do
        release.pop
        ran_on = Thread.current
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 0.5
      expect(ran_on).to be_nil

      release << true
      expect(described_class.flush(2)).to be true
      expect(ran_on).not_to eq(Thread.current)
    end

    it "runs the job inline when async_logging is off" do
      Coolhand.configuration.async_logging = false
      ran_on = nil

      described_class.submit { ran_on = Thread.current }

      expect(ran_on).to eq(Thread.current)
    end

    it "runs the job inline in debug mode so printed payloads stay ordered" do
      Coolhand.configuration.debug_mode = true
      ran_on = nil

      described_class.submit { ran_on = Thread.current }

      expect(ran_on).to eq(Thread.current)
    end

    it "runs jobs submitted from the worker thread inline instead of re-queueing them" do
      inner_ran_on = nil
      outer_thread = nil

      described_class.submit do
        outer_thread = Thread.current
        described_class.submit { inner_ran_on = Thread.current }
      end
      described_class.flush(2)

      expect(inner_ran_on).to eq(outer_thread)
    end

    it "keeps working after a job raises" do
      allow(Coolhand).to receive(:log)
      ran = false

      described_class.submit { raise "boom" }
      described_class.submit { ran = true }
      described_class.flush(2)

      expect(ran).to be true
      expect(Coolhand).to have_received(:log).with(a_string_including("boom"))
    end

    it "drops the oldest pending job when the queue is full" do
      allow(Coolhand).to receive(:log)
      stub_const("#{described_class}::MAX_QUEUE_SIZE", 2)
      release = Queue.new
      started = Queue.new
      ran = []

      described_class.submit do
        started << true
        release.pop
      end
      started.pop # worker is now busy, so the next submits stay queued
      %i[a b c].each { |name| described_class.submit { ran << name } }

      release << true
      described_class.flush(2)

      expect(ran).to eq(%i[b c])
      expect(Coolhand).to have_received(:log).with(a_string_including("dropping the oldest"))
    end

    it "runs batch-lane jobs on their own thread so a long batch doesn't block default-lane jobs" do
      release = Queue.new
      started = Queue.new
      default_ran = false

      described_class.submit(lane: :batch) do
        started << true
        release.pop
      end
      started.pop
      described_class.submit { default_ran = true }
      wait_until { default_ran }

      expect(default_ran).to be true
      release << true
      expect(described_class.flush(2)).to be true
    end

    it "runs a batch job's nested submits inline on the batch thread" do
      outer = inner = nil
      described_class.submit(lane: :batch) do
        outer = Thread.current
        described_class.submit { inner = Thread.current }
      end
      described_class.flush(2)

      expect(inner).to eq(outer)
    end

    it "discards the parent's pending jobs in a forked child" do
      release = Queue.new
      started = Queue.new
      ran = []
      described_class.submit do
        started << true
        release.pop
      end
      started.pop
      described_class.submit { ran << :parent_pending }

      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      described_class.submit { ran << :child }
      release << true
      described_class.flush(2)

      expect(ran).to eq([:child])
    end

    it "starts a fresh worker in a forked child" do
      first_thread = nil
      described_class.submit { first_thread = Thread.current }
      described_class.flush(2)

      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      second_thread = nil
      described_class.submit { second_thread = Thread.current }
      described_class.flush(2)

      expect(second_thread).not_to be_nil
      expect(second_thread).not_to eq(first_thread)
    end
  end

  describe ".flush" do
    it "returns true immediately when nothing was ever queued" do
      expect(described_class.flush(0.1)).to be true
    end

    it "restarts the worker on the next submit after a job kills it" do
      described_class.submit { raise NoMemoryError, "simulated" }
      wait_until { !described_class::LANES[:default].thread.alive? }
      ran = false
      described_class.submit { ran = true }

      expect(described_class.flush(2)).to be true
      expect(ran).to be true
    end

    it "returns false when the queue does not drain before the timeout" do
      release = Queue.new
      described_class.submit { release.pop }

      expect(described_class.flush(0.1)).to be false
      release << true
    end
  end

  describe ".await_delivery" do
    it "returns :none when nothing is pending for the id" do
      expect(described_class.await_delivery("nope", timeout: 0.1)).to eq(:none)
    end

    it "returns :none when the job ran inline" do
      Coolhand.configuration.async_logging = false
      described_class.submit(client_unique_id: "abc.1") { :sent }

      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:none)
    end

    it "waits for the job and returns :delivered when it returns a result" do
      release = Queue.new
      described_class.submit(client_unique_id: "abc.1") { release.pop }

      result = Thread.new { described_class.await_delivery("abc.1", timeout: 2) }
      sleep 0.01 until result.status == "sleep"
      expect(result).to be_alive
      release << { id: "log" }

      expect(result.value).to eq(:delivered)
    end

    it "returns :failed when the job returns nil" do
      described_class.submit(client_unique_id: "abc.1") { nil }

      expect(described_class.await_delivery("abc.1", timeout: 2)).to eq(:failed)
    end

    it "returns :failed when the job raises" do
      allow(Coolhand).to receive(:log)
      described_class.submit(client_unique_id: "abc.1") { raise "boom" }

      expect(described_class.await_delivery("abc.1", timeout: 2)).to eq(:failed)
    end

    it "returns :timeout while the job is still running" do
      release = Queue.new
      described_class.submit(client_unique_id: "abc.1") { release.pop }

      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:timeout)
      release << true
    end

    it "ignores unrelated jobs ahead of and behind it" do
      release = Queue.new
      started = Queue.new
      described_class.submit(lane: :batch) do
        started << true
        release.pop
      end
      started.pop
      described_class.submit(client_unique_id: "mine") { :sent }
      described_class.submit(client_unique_id: "other") { release.pop }

      expect(described_class.await_delivery("mine", timeout: 2)).to eq(:delivered)
      release << true
      release << true
    end

    it "waits for every log that shares the id" do
      release = Queue.new
      described_class.submit(client_unique_id: "abc.1") { :sent }
      described_class.submit(client_unique_id: "abc.1") { release.pop }

      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:timeout)
      release << true
      expect(described_class.await_delivery("abc.1", timeout: 2)).to eq(:delivered)
    end

    it "returns :failed for a job dropped from a full queue" do
      allow(Coolhand).to receive(:log)
      stub_const("#{described_class}::MAX_QUEUE_SIZE", 1)
      release = Queue.new
      started = Queue.new
      described_class.submit do
        started << true
        release.pop
      end
      started.pop
      described_class.submit(client_unique_id: "dropped") { :sent }
      described_class.submit { :newer }

      expect(described_class.await_delivery("dropped", timeout: 2)).to eq(:failed)
      release << true
    end

    it "settles a tracked job whose enqueue raises, then re-raises" do
      allow(described_class::LANES[:default]).to receive(:enqueue).and_raise(ThreadError)

      expect { described_class.submit(client_unique_id: "abc.1") { :sent } }.to raise_error(ThreadError)
      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:failed)
    end

    it "forgets delivered jobs" do
      described_class.submit(client_unique_id: "abc.1") { :sent }
      described_class.flush(2)

      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:none)
    end

    it "remembers a failed send for later callers until the id is delivered" do
      sent = [nil, :sent].each
      described_class.submit(client_unique_id: "abc.1") { sent.next }
      described_class.flush(2)
      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:failed)

      described_class.submit(client_unique_id: "abc.1") { sent.next }
      described_class.flush(2)
      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:none)
    end

    it "bounds how many failed ids it remembers" do
      stub_const("#{described_class}::Deliveries::MAX_FAILED_IDS", 2)
      %w[a b c].each { |id| described_class.submit(client_unique_id: id) { nil } }
      described_class.flush(2)

      expect(%w[a b c].map { |id| described_class.await_delivery(id, timeout: 0.1) }).to eq(%i[none failed failed])
    end

    it "does not see the parent's pending jobs in a forked child" do
      release = Queue.new
      described_class.submit(client_unique_id: "abc.1") { release.pop }

      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:none)
      release << true
    end
  end

  describe "NetHttpInterceptor integration" do
    let(:api_service) { instance_double(Coolhand::ApiService) }

    before do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = ["api.test.com"]
        c.async_logging = true
      end
      allow(Coolhand::ApiService).to receive(:new).and_return(api_service)
      stub_request(:get, "https://api.test.com/hello").to_return(status: 200, body: '{"msg":"hi"}')
    end

    it "does not make the intercepted request wait for a slow Coolhand POST" do
      release = Queue.new
      allow(api_service).to receive(:send_llm_request_log) { release.pop }

      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      response = Timeout.timeout(1) { http.request(Net::HTTP::Get.new(uri)) }

      expect(response.code).to eq("200")
      release << true
      expect(Coolhand.flush(timeout: 2)).to be true
      expect(api_service).to have_received(:send_llm_request_log).once
    end

    it "lets feedback wait for the log carrying its client_unique_id" do
      release = Queue.new
      allow(api_service).to receive(:send_llm_request_log) { release.pop }

      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      Coolhand.with_context(client_unique_id: "abc.1") { http.request(Net::HTTP::Get.new(uri)) }

      expect(described_class.await_delivery("abc.1", timeout: 0.1)).to eq(:timeout)
      release << { id: "log" }
      expect(described_class.await_delivery("abc.1", timeout: 2)).to eq(:delivered)
    end

    it "reports a failed log send to anyone waiting on its client_unique_id" do
      allow(api_service).to receive(:send_llm_request_log).and_return(nil)

      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      Coolhand.with_context(client_unique_id: "abc.1") { http.request(Net::HTTP::Get.new(uri)) }

      expect(described_class.await_delivery("abc.1", timeout: 2)).to eq(:failed)
    end
  end

  describe "delivery failures" do
    it "makes flush return false after a recorded failure, then true once reported" do
      described_class.record_failure

      expect(described_class.flush(2)).to be false
      expect(described_class.flush(2)).to be true
    end

    it "keeps a failure for the next flush when the first one timed out" do
      release = Queue.new
      described_class.submit { release.pop }
      described_class.record_failure

      expect(described_class.flush(0.05)).to be false
      release << true
      expect(described_class.flush(2)).to be false
      expect(described_class.flush(2)).to be true
    end

    it "does not carry a parent process's failures into a forked child" do
      described_class.record_failure
      allow(Process).to receive(:pid).and_return(Process.pid + 1)

      expect(described_class.flush(2)).to be true
    end

    it "reports a job that raised, since its log was never sent" do
      described_class.submit { raise "boom" }

      expect(described_class.flush(2)).to be false
    end

    it "reports a pending log dropped because the queue was full" do
      release = Queue.new
      described_class.submit { release.pop }
      wait_until { described_class::LANES[:default].thread&.alive? }
      stub_const("Coolhand::LogQueue::MAX_QUEUE_SIZE", 1)
      described_class.submit { nil }
      described_class.submit { nil }
      release << true

      expect(described_class.flush(2)).to be false
    end

    it "reports a tracked log dropped because the queue was full, and settles it as failed" do
      release = Queue.new
      described_class.submit { release.pop }
      wait_until { described_class::LANES[:default].thread&.alive? }
      stub_const("Coolhand::LogQueue::MAX_QUEUE_SIZE", 1)
      described_class.submit(client_unique_id: "dropped") { :sent }
      described_class.submit { :newer }
      release << true

      expect(described_class.flush(2)).to be false
      expect(described_class.await_delivery("dropped", timeout: 1)).to eq(:failed)
    end

    it "reports a failed send made by a queued job" do
      Coolhand.configuration.api_key = "k"
      stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs").to_return(status: 400, body: "no")
      described_class.submit do
        Coolhand::ApiService.new.send_llm_request_log(method: "POST", url: "https://x.test", status_code: 200)
      end

      expect(described_class.flush(2)).to be false
    end
  end
end
