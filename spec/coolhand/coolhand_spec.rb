# frozen_string_literal: true

RSpec.describe Coolhand do
  let(:config) { Coolhand.configuration }

  before { config.silent = true }

  it "has a version number" do
    expect(Coolhand::VERSION).not_to be_nil
  end

  describe ".configure" do
    it "yields configuration" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
      end

      expect(config.api_key).to eq("test-key")
    end

    it "raises error if api_key is missing" do
      expect do
        Coolhand.configure do |c|
          c.silent = true
          c.api_key = nil
        end
      end.to raise_error(Coolhand::Error, /API Key is required/)
    end

    it "preserves default intercept_addresses when set to nil" do
      # Setting to nil should preserve the defaults
      expect do
        Coolhand.configure do |c|
          c.api_key = "test-key"
          c.silent = true
          c.intercept_addresses = nil
        end
      end.not_to raise_error

      expect(Coolhand.configuration.intercept_addresses).to eq(["api.openai.com",
                                                                "api.elevenlabs.io",
                                                                ":generateContent"])
    end

    it "calls Interceptor.patch!" do
      expect(Coolhand::NetHttpInterceptor).to receive(:patch!)
      Coolhand.configure do |c|
        c.api_key = "key"
        c.silent = true
        # Empty array preserves defaults
        c.intercept_addresses = []
      end

      expect(Coolhand.configuration.intercept_addresses).to eq(["api.openai.com",
                                                                "api.elevenlabs.io",
                                                                ":generateContent"])
    end

    it "allows custom intercept_addresses to be set" do
      expect(Coolhand::NetHttpInterceptor).to receive(:patch!)
      Coolhand.configure do |c|
        c.api_key = "key"
        c.silent = true
        c.intercept_addresses = ["custom.api.com"]
      end

      expect(Coolhand.configuration.intercept_addresses).to eq(["custom.api.com"])
    end
  end

  describe "debug_mode config" do
    it "defaults to false" do
      expect(config.debug_mode).to be false
    end

    it "can be set to true via configure" do
      expect(Coolhand::NetHttpInterceptor).to receive(:patch!)
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.debug_mode = true
      end

      expect(config.debug_mode).to be true
    end
  end

  describe "capture config" do
    it "defaults to true" do
      expect(config.capture).to be true
    end

    it "can be set to false" do
      config.capture = false
      expect(config.capture).to be false
    end
  end

  describe ".without_capture" do
    it "sets thread-local override to false within the block" do
      Coolhand.without_capture do
        expect(Thread.current[:coolhand_capture_override]).to be false
      end
    end

    it "restores previous thread-local state after the block" do
      Coolhand.without_capture do
        # inside block
      end
      expect(Thread.current[:coolhand_capture_override]).to be_nil
    end

    it "restores state even if block raises" do
      begin
        Coolhand.without_capture do
          raise "boom"
        end
      rescue RuntimeError
        # expected
      end
      expect(Thread.current[:coolhand_capture_override]).to be_nil
    end

    it "handles nested calls correctly" do
      Coolhand.without_capture do
        expect(Thread.current[:coolhand_capture_override]).to be false
        Coolhand.with_capture do
          expect(Thread.current[:coolhand_capture_override]).to be true
        end
        expect(Thread.current[:coolhand_capture_override]).to be false
      end
    end
  end

  describe ".with_capture" do
    it "sets thread-local override to true within the block" do
      Coolhand.with_capture do
        expect(Thread.current[:coolhand_capture_override]).to be true
      end
    end

    it "restores previous thread-local state after the block" do
      Coolhand.with_capture do
        # inside block
      end
      expect(Thread.current[:coolhand_capture_override]).to be_nil
    end

    it "restores state even if block raises" do
      begin
        Coolhand.with_capture do
          raise "boom"
        end
      rescue RuntimeError
        # expected
      end
      expect(Thread.current[:coolhand_capture_override]).to be_nil
    end
  end

  describe ".capture" do
    it "yields the block and calls patch/unpatch" do
      called = false

      expect(Coolhand::NetHttpInterceptor).to receive(:patch!).ordered
      expect(Coolhand::NetHttpInterceptor).not_to receive(:unpatch!).ordered

      Coolhand.capture do
        called = true
      end

      expect(called).to be true
    end

    it "warns if no block given" do
      config.silent = false
      expect { Coolhand.capture }.to output(/requires block/).to_stdout
    end
  end

  describe ".log" do
    it "prints message if not silent" do
      config.silent = false
      expect { Coolhand.log("hello") }.to output(/hello/).to_stdout
    end

    it "does not print if silent" do
      config.silent = true
      expect { Coolhand.log("hello") }.not_to output.to_stdout
    end
  end

  describe ".required_field?" do
    it "returns true for valid values" do
      expect(Coolhand.required_field?("valid")).to be true
      expect(Coolhand.required_field?("  valid  ")).to be true
      expect(Coolhand.required_field?(123)).to be true
      expect(Coolhand.required_field?(["item"])).to be true
    end

    it "returns false for invalid values" do
      expect(Coolhand.required_field?(nil)).to be false
      expect(Coolhand.required_field?("")).to be false
      expect(Coolhand.required_field?("   ")).to be false
      expect(Coolhand.required_field?([])).to be false
      expect(Coolhand.required_field?({})).to be false
    end
  end
end
