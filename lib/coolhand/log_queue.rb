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
  module LogQueue
    MAX_QUEUE_SIZE = 1000
    DEFAULT_FLUSH_TIMEOUT = 5

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

          while @jobs.any? || @busy
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false unless remaining.positive?

            @idle.wait(@mutex, remaining)
          end
          true
        end
      end

      def reset!
        thread = nil
        @mutex.synchronize do
          thread = @thread
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

      def drop_oldest
        @jobs.shift
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

    @at_exit_mutex = Mutex.new
    @at_exit_registered = false

    class << self
      def submit(lane: :default, &job)
        return yield unless async?

        register_at_exit
        LANES.fetch(lane).enqueue(job)
        nil
      end

      # Blocks until every queued job has finished or the timeout elapses. Returns true when
      # every lane drained in time.
      def flush(timeout = DEFAULT_FLUSH_TIMEOUT)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        LANES.values.map { |lane| lane.flush(deadline) }.all?
      end

      # Testing-only: discard queued work and stop the workers.
      def reset!
        LANES.each_value(&:reset!)
      end

      private

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
