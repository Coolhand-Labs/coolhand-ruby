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

    it "does not raise when api_key is missing — validation is deferred to first use" do
      expect(Coolhand::NetHttpInterceptor).to receive(:patch!)
      expect do
        Coolhand.configure do |c|
          c.silent = true
          c.api_key = nil
        end
      end.not_to raise_error
    end

    context "when enabled is false" do
      it "does not call validate! or patch! and does not raise even with nil api_key" do
        expect(Coolhand::NetHttpInterceptor).not_to receive(:patch!)
        expect do
          Coolhand.configure do |c|
            c.enabled = false
            c.silent = true
            c.api_key = nil
          end
        end.not_to raise_error
      end

      it "stores config settings even when disabled" do
        Coolhand.configure do |c|
          c.enabled = false
          c.silent = true
          c.environment = "staging"
        end
        expect(config.environment).to eq("staging")
        expect(config.enabled).to be false
      end
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

      expect(Coolhand.configuration.intercept_addresses).to eq(Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES)
    end

    it "calls Interceptor.patch!" do
      expect(Coolhand::NetHttpInterceptor).to receive(:patch!)
      Coolhand.configure do |c|
        c.api_key = "key"
        c.silent = true
        # Empty array preserves defaults
        c.intercept_addresses = []
      end

      expect(Coolhand.configuration.intercept_addresses).to eq(Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES)
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

  describe "base_url config" do
    before { allow(Coolhand::NetHttpInterceptor).to receive(:patch!) }

    it "defaults to https://coolhandlabs.com/api" do
      expect(config.base_url).to eq("https://coolhandlabs.com/api")
    end

    it "accepts a custom https:// URL" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.base_url = "https://self-hosted.example.com/api"
      end
      expect(config.base_url).to eq("https://self-hosted.example.com/api")
    end

    it "accepts http://localhost for local dev" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.base_url = "http://localhost:3000/api"
      end
      expect(config.base_url).to eq("http://localhost:3000/api")
    end

    it "accepts http://127.0.0.1 for local dev" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.base_url = "http://127.0.0.1:3000/api"
      end
      expect(config.base_url).to eq("http://127.0.0.1:3000/api")
    end

    it "raises an error for non-https, non-localhost URLs" do
      expect do
        Coolhand.configure do |c|
          c.api_key = "test-key"
          c.silent = true
          c.base_url = "http://example.com/api"
        end
      end.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises an error for http://localhost-prefixed hostnames (security: exact host match)" do
      expect do
        Coolhand.configure do |c|
          c.api_key = "test-key"
          c.silent = true
          c.base_url = "http://localhost.attacker.com/api"
        end
      end.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises an error for http://127.0.0.1-prefixed hostnames (security: exact host match)" do
      expect do
        Coolhand.configure do |c|
          c.api_key = "test-key"
          c.silent = true
          c.base_url = "http://127.0.0.1.evil.com/api"
        end
      end.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises an error when base_url is set to nil" do
      expect do
        Coolhand.configure do |c|
          c.api_key = "test-key"
          c.silent = true
          c.base_url = nil
        end
      end.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "strips trailing slashes" do
      config.base_url = "https://self-hosted.example.com/api/"
      expect(config.base_url).to eq("https://self-hosted.example.com/api")
    end

    it "strips multiple trailing slashes" do
      config.base_url = "https://self-hosted.example.com/api///"
      expect(config.base_url).to eq("https://self-hosted.example.com/api")
    end

    it "accepts mixed-case localhost (case-insensitive host match)" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.base_url = "http://LOCALHOST:3000/api"
      end
      expect(config.base_url).to eq("http://LOCALHOST:3000/api")
    end

    it "accepts http://[::1] IPv6 loopback for local dev" do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.base_url = "http://[::1]:3000/api"
      end
      expect(config.base_url).to eq("http://[::1]:3000/api")
    end

    it "raises for https:// with no host" do
      expect { config.base_url = "https://" }.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises for https: with nil host" do
      expect { config.base_url = "https:" }.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises for an empty string" do
      expect { config.base_url = "" }.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises for a malformed URL (locks in URI::InvalidURIError rescue)" do
      expect { config.base_url = "http://[bad" }.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises for http://0.0.0.0 (loopback-looking but not a valid local-dev host)" do
      expect { config.base_url = "http://0.0.0.0/api" }.to raise_error(Coolhand::Error, /base_url must use https/)
    end

    it "raises immediately on direct setter assignment without configure (eager validation)" do
      expect { Coolhand.configuration.base_url = "http://evil.com/api" }
        .to raise_error(Coolhand::Error, /base_url must use https/)
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

  describe "Gemini default configuration" do
    it "includes generativelanguage.googleapis.com in default intercept_addresses" do
      fresh_config = Coolhand::Configuration.new
      expect(fresh_config.intercept_addresses).to include("generativelanguage.googleapis.com")
    end

    it "includes :streamGenerateContent in default intercept_addresses" do
      fresh_config = Coolhand::Configuration.new
      expect(fresh_config.intercept_addresses).to include(":streamGenerateContent")
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
