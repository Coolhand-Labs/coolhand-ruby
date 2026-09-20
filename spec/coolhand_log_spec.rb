# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand do
  describe ".log" do
    before { Coolhand.configure { |c| c.silent = false } }

    after { Coolhand.configure { |c| c.silent = true } }

    it "never raises into the caller when stdout is unwritable" do
      allow(Coolhand).to receive(:puts).and_raise(IOError, "closed stream")

      expect { Coolhand.log("hello") }.not_to raise_error
    end
  end
end
