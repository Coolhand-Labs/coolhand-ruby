# frozen_string_literal: true

module Coolhand
  # Runs log-shipping work on background threads so a slow or unreachable Coolhand backend can't
  # add latency to the host app's own LLM calls.
  #
  # Work is spread over two lanes, each with its own bounded queue and worker thread: `:default`
  # for the one-log-per-intercepted-call sends, and `:batch` for whole-batch jobs (download +
  # one send per item) that can run for minutes. Keeping them apart stops a long batch from
  # delaying — or, once the queue fills, evicting — the real-time logs.
  #
  # Each queue is bounded (oldest job dropped when full), restarts itself in a forked child, and
  # is flushed at process exit. Work runs inline instead when `config.async_logging` is false,
  # when `config.debug_mode` is on (debug output should appear in order), or when the caller is
  # already a worker thread (a queued job's own sends don't re-enter a queue).
  #
  # A job submitted with a `client_unique_id` is also tracked, so {LogQueue.await_delivery} can wait
  # for that one log (not the whole queue) and learn whether its send actually succeeded.
  module LogQueue
    MAX_QUEUE_SIZE = 1000
    DEFAULT_FLUSH_TIMEOUT = 5

    # Delivery state of one queued job: pending until the job returns (delivered when it returned a
    # non-nil result, failed when it returned nil, raised, or was dropped before it ran).
    class Delivery
      def initialize
        @mutex = Mutex.new
        @done = ConditionVariable.new
        @state = nil
      end

      def finish(delivered)
        @mutex.synchronize do
          @state ||= delivered ? :delivered : :failed
          @done.broadcast
        end
      end

      # The final state (:delivered or :failed), or nil if the deadline passed first.
      def wait(deadline)
        @mutex.synchronize do
          loop do
            return @state if @state
            return nil unless LogQueue.wait_for(@done, @mutex, deadline)
          end
        end
      end
    end

    # Wraps a job so its outcome lands on a Delivery and its registry entry is always cleared.
    class TrackedJob
      def initialize(job, delivery, on_settle)
        @job = job
        @delivery = delivery
        @on_settle = on_settle
      end

      def call
        delivered = false
        begin
          result = @job.call
          delivered = !result.nil?
          result
        ensure
          settle(delivered)
        end
      end

      # The job was discarded before it could run (queue full, reset).
      def abandon
        settle(false)
      end

      private

      def settle(delivered)
        @delivery.finish(delivered)
        @on_settle.call(delivered)
      end
    end

    # The pending deliveries, keyed by client_unique_id (several logs may share an id), plus the
    # most recent ids whose last send failed, so feedback arriving after the fact still sees it.
    class Deliveries
      MAX_FAILED_IDS = 1000

      def initialize
        @mutex = Mutex.new
        @by_id = Hash.new { |hash, id| hash[id] = [] }
        @failed = {}
        @pid = Process.pid
      end

      def track(client_unique_id, job)
        delivery = Delivery.new
        @mutex.synchronize do
          drop_inherited_entries
          @by_id[client_unique_id] << delivery
        end
        TrackedJob.new(job, delivery, ->(delivered) { settle(client_unique_id, delivery, delivered) })
      end

      # [pending deliveries, whether the id's last finished send failed]
      def snapshot(client_unique_id)
        @mutex.synchronize do
          drop_inherited_entries
          [@by_id.key?(client_unique_id) ? @by_id[client_unique_id].dup : [], @failed.key?(client_unique_id)]
        end
      end

      def clear
        @mutex.synchronize do
          @by_id.clear
          @failed.clear
        end
      end

      private

      def settle(client_unique_id, delivery, delivered)
        @mutex.synchronize do
          remember_outcome(client_unique_id, delivered)
          next unless @by_id.key?(client_unique_id)

          @by_id[client_unique_id].delete(delivery)
          @by_id.delete(client_unique_id) if @by_id[client_unique_id].empty?
        end
      end

      def remember_outcome(client_unique_id, delivered)
        @failed.delete(client_unique_id)
        return if delivered

        @failed[client_unique_id] = true
        @failed.shift while @failed.size > MAX_FAILED_IDS
      end

      # A forked child inherits the parent's entries but not the worker that would settle them.
      def drop_inherited_entries
        return if @pid == Process.pid

        @pid = Process.pid
        @by_id.clear
        @failed.clear
      end
    end

    # One bounded FIFO plus the thread that drains it.
    class Lane
      attr_reader :thread

      def initialize
        @mutex = Mutex.new
        @wakeup = ConditionVariable.new
        @idle = ConditionVariable.new
        @jobs = []
        @thread = nil
        @pid = Process.pid
        @busy = false
      end

      def enqueue(job)
        @mutex.synchronize do
          restart_after_fork
          drop_oldest if @jobs.size >= MAX_QUEUE_SIZE
          @jobs << job
          ensure_worker
          @wakeup.signal
        end
      end

      # True once every queued job has finished, false if the timeout elapsed first.
      def flush(deadline)
        @mutex.synchronize do
          # A forked child's copy of the queue belongs to the parent's worker; nothing to wait on.
          return true if @pid != Process.pid
          # A dead worker will never drain the queue, so don't wait on it.
          return @jobs.empty? unless @thread&.alive?

          wait_until_drained(deadline)
        end
      end

      def reset!
        thread = nil
        @mutex.synchronize do
          thread = @thread
          abandon(@jobs)
          @jobs.clear
          @thread = nil
          @busy = false
          @wakeup.broadcast
          @idle.broadcast
        end
        thread&.join(1)
        thread&.kill if thread&.alive?
      end

      private

      # The caller holds the mutex.
      def wait_until_drained(deadline)
        loop do
          return true unless @jobs.any? || @busy
          return false unless LogQueue.wait_for(@idle, @mutex, deadline)
        end
      end

      def abandon(jobs)
        jobs.each { |job| job.abandon if job.respond_to?(:abandon) }
      end

      def drop_oldest
        abandon([@jobs.shift])
        Coolhand.log "⚠️ Log queue full (#{MAX_QUEUE_SIZE}); dropping the oldest pending log"
      end

      # A forked child inherits the queue's memory but not its worker thread.
      def restart_after_fork
        return if @pid == Process.pid

        @pid = Process.pid
        @jobs = []
        @thread = nil
        @busy = false
      end

      def ensure_worker
        return if @thread&.alive?

        @thread = Thread.new { work }
        @thread.report_on_exception = false
      end

      def work
        loop do
          job = next_job
          break unless job

          begin
            run(job)
          ensure
            @mutex.synchronize do
              @busy = false
              @idle.broadcast
            end
          end
        end
      end

      def next_job
        @mutex.synchronize do
          @wakeup.wait(@mutex) while @jobs.empty? && @thread == Thread.current
          return nil unless @thread == Thread.current

          @busy = true
          @jobs.shift
        end
      end

      def run(job)
        job.call
      rescue StandardError => e
        Coolhand.log "❌ Error in background log job: #{e.message}"
      end
    end

    LANES = { default: Lane.new, batch: Lane.new }.freeze
    DELIVERIES = Deliveries.new

    @at_exit_mutex = Mutex.new
    @at_exit_registered = false

    class << self
      # Queues the job on a background lane, or runs it inline (see the module comment). With a
      # `client_unique_id`, the job's outcome is tracked for {await_delivery}: it counts as delivered
      # when the block returns a non-nil value, and as failed when it returns nil or raises.
      def submit(lane: :default, client_unique_id: nil, &job)
        return yield unless async?

        register_at_exit
        job = DELIVERIES.track(client_unique_id, job) if client_unique_id
        enqueue_or_abandon(LANES.fetch(lane), job)
        nil
      end

      # Waits for the queued log(s) carrying this client_unique_id, ignoring everything else in the
      # queue. Returns :delivered or :failed once its send has completed (:failed also covers a send
      # that failed earlier and hasn't been retried), :timeout if it is still sending, or :none when
      # this process has no record of it (sent inline, or never queued here).
      def await_delivery(client_unique_id, timeout: DEFAULT_FLUSH_TIMEOUT)
        deliveries, failed_earlier = DELIVERIES.snapshot(client_unique_id)
        return (failed_earlier ? :failed : :none) if deliveries.empty?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        states = deliveries.map { |delivery| delivery.wait(deadline) }
        return :timeout if states.include?(nil)

        states.include?(:delivered) ? :delivered : :failed
      end

      # Blocks until every queued job has finished or the timeout elapses. Returns true when
      # every lane drained in time.
      def flush(timeout = DEFAULT_FLUSH_TIMEOUT)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        LANES.values.map { |lane| lane.flush(deadline) }.all?
      end

      # One condition-variable wait bounded by a monotonic deadline (the caller holds the mutex and
      # re-checks its condition). False once the deadline has passed.
      def wait_for(condition, mutex, deadline)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false unless remaining.positive?

        condition.wait(mutex, remaining)
        true
      end

      # Testing-only: discard queued work and stop the workers.
      def reset!
        LANES.each_value(&:reset!)
        DELIVERIES.clear
      end

      private

      # A tracked job that never reaches the queue must still settle, or waiters would hang on it.
      def enqueue_or_abandon(lane, job)
        lane.enqueue(job)
      rescue StandardError
        job.abandon if job.respond_to?(:abandon)
        raise
      end

      def async?
        Coolhand.configuration.async_logging && !Coolhand.configuration.debug_mode && !worker_thread?
      end

      def worker_thread?
        LANES.each_value.any? { |lane| lane.thread == Thread.current }
      end

      def register_at_exit
        @at_exit_mutex.synchronize do
          return if @at_exit_registered

          @at_exit_registered = true
          at_exit { flush }
        end
      end
    end
  end
end
