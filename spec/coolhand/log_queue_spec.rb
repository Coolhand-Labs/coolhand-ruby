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
  end
end
