# frozen_string_literal: true

module Coolhand
  module OpenAi
    # Thread-safe, in-memory, TTL-bounded store used to detect replayed
    # `webhook-id` values. This is the default for
    # `Coolhand.configuration.webhook_id_store` and only dedupes within a
    # single process - deployments running multiple processes/dynos should
    # supply their own store (e.g. backed by Rails.cache) via configuration.
    class WebhookIdStore
      def initialize
        @entries = {}
        @mutex = Mutex.new
      end

      # Atomically checks-and-records `id` in a single critical section, so
      # two concurrent replays of the same id can't both observe "unseen"
      # before either records it. Returns true the first time `id` is
      # claimed, false if it was already claimed within its TTL.
      def claim!(id, ttl_seconds)
        @mutex.synchronize do
          prune
          return false if @entries.key?(id)

          @entries[id] = Time.now.to_i + ttl_seconds
          true
        end
      end

      def seen?(id)
        @mutex.synchronize do
          prune
          @entries.key?(id)
        end
      end

      private

      def prune
        now = Time.now.to_i
        @entries.delete_if { |_id, expires_at| expires_at < now }
      end
    end
  end
end
