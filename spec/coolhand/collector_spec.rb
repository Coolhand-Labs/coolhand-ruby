# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Collector do
  describe ".get_collector_string" do
    it "returns base collector string without method" do
      expect(described_class.get_collector_string).to eq("coolhand-ruby-#{Coolhand::VERSION}")
    end

    it "returns collector string with manual method" do
      expect(described_class.get_collector_string("manual")).to eq("coolhand-ruby-#{Coolhand::VERSION}-manual")
    end

    it "returns collector string with auto-monitor method" do
      expect(described_class.get_collector_string("auto-monitor")).to eq("coolhand-ruby-#{Coolhand::VERSION}-auto-monitor")
    end

    it "ignores invalid method and returns base string" do
      expect(described_class.get_collector_string("invalid")).to eq("coolhand-ruby-#{Coolhand::VERSION}")
    end

    it "handles nil method" do
      expect(described_class.get_collector_string(nil)).to eq("coolhand-ruby-#{Coolhand::VERSION}")
    end
  end
end
