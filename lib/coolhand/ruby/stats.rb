# frozen_string_literal: true

module Coolhand
  # A simple, thread-safe module to track statistics.
  module Stats
    @intercepted_calls = 0
    @mutex = Mutex.new

    def self.increment_intercepted_calls
      @mutex.synchronize { @intercepted_calls += 1 }
    end

    def self.intercepted_calls
      @mutex.synchronize { @intercepted_calls }
    end

    def self.get
      {
        intercepted_calls: intercepted_calls,
        environment: Coolhand.configuration.environment,
        api_endpoint: Coolhand.configuration.api_endpoint
      }
    end
  end
end