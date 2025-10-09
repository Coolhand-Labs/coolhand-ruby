# frozen_string_literal: true

RSpec.describe Coolhand::Ruby do
  let(:config) { Coolhand.configuration }

  before { config.silent = true }

  it "has a version number" do
    expect(Coolhand::Ruby::VERSION).not_to be_nil
  end

  describe ".configure" do
    it "yields configuration" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.api_endpoint = "https://example.com"
        c.silent = true
      end

      expect(config.api_key).to eq("test-key")
      expect(config.api_endpoint).to eq("https://example.com")
    end

    it "raises error if api_key is missing" do
      expect do
        Coolhand.configure do |c|
          c.api_endpoint = "https://example.com"
          c.silent = true
          c.api_key = nil
        end
      end.to raise_error(Coolhand::Error, /API Key is required/)
    end

    it "raises error if api_endpoint is missing" do
      expect do
        Coolhand.configure do |c|
          c.api_key = "test-key"
          c.silent = true
          c.api_endpoint = nil
        end
      end.to raise_error(Coolhand::Error, /API Endpoint is required/)
    end

    it "calls Interceptor.patch!" do
      expect(Coolhand::Interceptor).to receive(:patch!)
      Coolhand.configure do |c|
        c.api_key = "key"
        c.api_endpoint = "https://api"
        c.silent = true
      end
    end
  end

  describe ".capture" do
    it "yields the block and calls patch/unpatch" do
      called = false

      expect(Coolhand::Interceptor).to receive(:patch!).ordered
      expect(Coolhand::Interceptor).to receive(:unpatch!).ordered

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
end
