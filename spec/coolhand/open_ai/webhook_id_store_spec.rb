# frozen_string_literal: true

require "spec_helper"
require "coolhand/open_ai/webhook_id_store"

RSpec.describe Coolhand::OpenAi::WebhookIdStore do
  subject(:store) { described_class.new }

  describe "#claim!" do
    it "returns true the first time an id is claimed" do
      expect(store.claim!("wh_123", 300)).to be true
    end

    it "returns false for an id already claimed within its TTL" do
      store.claim!("wh_123", 300)
      expect(store.claim!("wh_123", 300)).to be false
    end

    it "returns true again once the previous claim's TTL has expired" do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      store.claim!("wh_123", 1)

      allow(Time).to receive(:now).and_return(now + 2)
      expect(store.claim!("wh_123", 300)).to be true
    end

    it "does not confuse distinct ids" do
      store.claim!("wh_123", 300)
      expect(store.claim!("wh_456", 300)).to be true
    end

    it "atomically claims under concurrent access, so only one caller wins per id" do
      results = Array.new(20) { Queue.new }

      threads = Array.new(20) do |i|
        Thread.new { results[i] << store.claim!("wh_concurrent", 300) }
      end
      threads.each(&:join)

      outcomes = results.map(&:pop)
      expect(outcomes.count(true)).to eq(1)
      expect(outcomes.count(false)).to eq(19)
    end
  end

  describe "#seen?" do
    it "returns false for an id that has never been claimed" do
      expect(store.seen?("wh_123")).to be false
    end

    it "returns true for an id that was claimed and hasn't expired" do
      store.claim!("wh_123", 300)
      expect(store.seen?("wh_123")).to be true
    end

    it "returns false for an id whose TTL has expired" do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      store.claim!("wh_123", 300)

      allow(Time).to receive(:now).and_return(now + 301)
      expect(store.seen?("wh_123")).to be false
    end
  end
end
