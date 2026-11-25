# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Configuration do
  describe "#inspect" do
    it "never prints the API key" do
      config = described_class.new
      config.api_key = "SECRETKEY123"

      expect(config.inspect).not_to include("SECRETKEY123")
      expect(config.inspect).to include("api_key=[REDACTED]")
    end

    it "shows nil when no key is set" do
      expect(described_class.new.inspect).to include("api_key=nil")
    end
  end
end
