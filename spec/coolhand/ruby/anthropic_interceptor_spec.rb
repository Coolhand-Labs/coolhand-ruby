# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::Ruby::AnthropicInterceptor do
  before do
    # Reset patched state before each test
    described_class.instance_variable_set(:@patched, false)
    allow(Coolhand).to receive(:log)
  end

  after do
    # Clean up after each test
    described_class.instance_variable_set(:@patched, false)
  end

  describe ".patch!" do
    context "when no Anthropic constant is defined" do
      before do
        # Hide Anthropic constant for this test
        hide_const("Anthropic") if defined?(Anthropic)
      end

      it "returns early without patching" do
        expect { described_class.patch! }.not_to(change(described_class, :patched?))
        expect(described_class.patched?).to be false
      end
    end

    context "when both anthropic gems are installed" do
      before do
        # Mock both gems being installed
        allow(described_class).to receive(:both_gems_installed?).and_return(true)

        # Ensure Anthropic constant exists for the test
        stub_const("Anthropic", Module.new) unless defined?(Anthropic)
      end

      it "shows warning message regardless of silent mode" do
        expect(described_class).to receive(:puts).with(
          "COOLHAND: ⚠️  Warning: Both 'anthropic' and 'ruby-anthropic' gems are installed. " \
          "Coolhand will only monitor ruby-anthropic (Faraday-based) requests. " \
          "Official anthropic gem monitoring has been disabled."
        )

        described_class.patch!
      end

      it "marks as patched and returns early" do
        allow(described_class).to receive(:puts) # Silence warning for this test

        described_class.patch!

        expect(described_class.patched?).to be true
      end

      it "does not attempt to patch official anthropic gem" do
        allow(described_class).to receive(:puts) # Silence warning for this test

        # Mock the official anthropic gem being present
        stub_const("Anthropic::Internal", Module.new)
        expect(described_class).not_to receive(:require).with("anthropic/internal/transport/base_client")

        described_class.patch!
      end
    end

    context "when only official anthropic gem is installed" do
      before do
        allow(described_class).to receive(:both_gems_installed?).and_return(false)

        # Mock official anthropic gem
        stub_const("Anthropic", Module.new)
        stub_const("Anthropic::Internal", Module.new)
        stub_const("Anthropic::Internal::Transport", Module.new)
        stub_const("Anthropic::Internal::Transport::BaseClient", Class.new)
        stub_const("Anthropic::Streaming", Module.new)
        stub_const("Anthropic::Streaming::MessageStream", Class.new)

        allow(described_class).to receive(:require).with("anthropic/internal/transport/base_client")
        allow(described_class).to receive(:require).with("anthropic/helpers/streaming/message_stream")
        allow(Anthropic::Internal::Transport::BaseClient).to receive(:prepend)
        allow(Anthropic::Streaming::MessageStream).to receive(:prepend)
      end

      it "patches the official anthropic gem" do
        described_class.patch!

        expect(described_class).to have_received(:require).with("anthropic/internal/transport/base_client")
        expect(Anthropic::Internal::Transport::BaseClient).to have_received(:prepend)
          .with(described_class::RequestInterceptor)
        expect(described_class.patched?).to be true
      end

      it "patches MessageStream for streaming support" do
        described_class.patch!

        expect(Anthropic::Streaming::MessageStream).to have_received(:prepend)
          .with(described_class::MessageStreamInterceptor)
      end
    end

    context "when only ruby-anthropic gem is installed" do
      before do
        allow(described_class).to receive(:both_gems_installed?).and_return(false)

        # Mock ruby-anthropic gem (no Anthropic::Internal)
        stub_const("Anthropic", Module.new)
        # Ensure Anthropic::Internal is not defined for this test
        hide_const("Anthropic::Internal") if defined?(Anthropic::Internal)
      end

      it "logs that ruby-anthropic is detected" do
        described_class.patch!

        expect(Coolhand).to have_received(:log).with("✅ ruby-anthropic detected, using Faraday interceptor")
        expect(described_class.patched?).to be true
      end

      it "does not attempt to patch official anthropic components" do
        expect(described_class).not_to receive(:require).with("anthropic/internal/transport/base_client")

        described_class.patch!
      end
    end

    context "when already patched" do
      before do
        described_class.instance_variable_set(:@patched, true)
      end

      it "returns early without doing anything" do
        expect(described_class).not_to receive(:both_gems_installed?)

        described_class.patch!
      end
    end
  end

  describe ".unpatch!" do
    it "marks as unpatched" do
      described_class.instance_variable_set(:@patched, true)

      described_class.unpatch!

      expect(described_class.patched?).to be false
      expect(Coolhand).to have_received(:log)
        .with("⚠️  Anthropic interceptor unpatch requested (not fully implemented)")
    end
  end

  describe ".both_gems_installed?" do
    context "when both gems are in loaded specs" do
      before do
        loaded_specs = {
          "anthropic" => instance_double(Gem::Specification, name: "anthropic"),
          "ruby-anthropic" => instance_double(Gem::Specification, name: "ruby-anthropic"),
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns true" do
        expect(described_class).to be_both_gems_installed
      end
    end

    context "when only anthropic gem is loaded" do
      before do
        loaded_specs = {
          "anthropic" => instance_double(Gem::Specification, name: "anthropic"),
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns false" do
        expect(described_class).not_to be_both_gems_installed
      end
    end

    context "when only ruby-anthropic gem is loaded" do
      before do
        loaded_specs = {
          "ruby-anthropic" => instance_double(Gem::Specification, name: "ruby-anthropic"),
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns false" do
        expect(described_class).not_to be_both_gems_installed
      end
    end

    context "when neither gem is loaded" do
      before do
        loaded_specs = {
          "other-gem" => instance_double(Gem::Specification, name: "other-gem")
        }
        allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)
      end

      it "returns false" do
        expect(described_class).not_to be_both_gems_installed
      end
    end
  end

  describe ".patched?" do
    it "returns false by default" do
      expect(described_class.patched?).to be false
    end

    it "returns true when @patched is set" do
      described_class.instance_variable_set(:@patched, true)
      expect(described_class.patched?).to be true
    end
  end
end
