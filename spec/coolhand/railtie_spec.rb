# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Coolhand::Railtie" do
  let(:hooks) { [] }

  # The file under test defines the constant at load, so it must be cleared by hand; stub_const cannot reopen it.
  def remove_railtie
    Coolhand.send(:remove_const, :Railtie) if Coolhand.const_defined?(:Railtie, false) # rubocop:disable RSpec/RemoveConst
  end

  # Rails is not a dependency of the gem, so a stand-in Railtie records the after_initialize block.
  before do
    recorded = hooks
    railtie_base = Class.new do
      define_singleton_method(:config) do
        Struct.new(:blocks) { def after_initialize(&block) = blocks << block }.new(recorded)
      end
    end
    stub_const("Rails", Module.new)
    stub_const("Rails::Railtie", railtie_base)
    remove_railtie
    load File.expand_path("../../lib/coolhand/railtie.rb", __dir__)
  end

  after { remove_railtie }

  it "installs the auto-declare hooks after the app has initialized" do
    allow(Coolhand::RailsAutoDeclare).to receive(:install)

    expect(hooks.size).to eq(1)
    hooks.first.call

    expect(Coolhand::RailsAutoDeclare).to have_received(:install)
  end
end
