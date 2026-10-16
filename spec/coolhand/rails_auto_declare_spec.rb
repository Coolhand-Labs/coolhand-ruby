# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::RailsAutoDeclare do
  # Rails is not a dependency of the gem, so ActiveSupport's load hooks and the ActiveJob/controller
  # callback DSLs are stood in for. Each fake runs the hook block against its base class immediately.
  let(:job_base) do
    Class.new do
      class << self
        def callbacks = (@callbacks ||= [])
        def around_perform(&block) = callbacks << block
      end
    end
  end
  let(:controller_base) do
    Class.new do
      class << self
        def callbacks = (@callbacks ||= [])
        def around_action(&block) = callbacks << block
      end
    end
  end
  let(:seen) { [] }
  let(:probe) { -> { seen << Coolhand::DeclaredContext.current } }

  before do
    bases = { active_job: job_base, action_controller: controller_base }
    stub_const("ActiveSupport", Module.new)
    ActiveSupport.define_singleton_method(:on_load) { |name, &block| bases.fetch(name).class_eval(&block) }
    described_class.reset!
  end

  after { described_class.reset! }

  def perform(job)
    job_base.callbacks.first.call(job, probe)
  end

  describe "config.auto_declare" do
    it "defaults to nothing and installs no hooks" do
      expect(Coolhand.configuration.auto_declare).to eq([])

      described_class.install

      expect(job_base.callbacks).to be_empty
      expect(controller_base.callbacks).to be_empty
    end

    it "normalizes to symbols and rejects unknown targets" do
      Coolhand.configuration.auto_declare = ["active_job", :controller, :controller]
      expect(Coolhand.configuration.auto_declare).to eq(%i[active_job controller])

      expect { Coolhand.configuration.auto_declare = [:sidekiq] }
        .to raise_error(Coolhand::Error, /auto_declare supports/)
    end
  end

  describe "active_job" do
    before do
      Coolhand.configuration.auto_declare = [:active_job]
      stub_const("SummariseJob", Class.new)
    end

    it "declares JobClass#perform around the job" do
      described_class.install
      perform(SummariseJob.new)

      expect(seen).to eq([{ source: "rails", workload: { key: "SummariseJob#perform" },
                            template: { key: "SummariseJob#perform" } }])
      expect(Coolhand::DeclaredContext.current).to be_nil
    end

    it "hooks only once however many times it is installed" do
      2.times { described_class.install }

      expect(job_base.callbacks.size).to eq(1)
      expect(controller_base.callbacks).to be_empty
    end

    it "leaves anonymous job classes and a disabled Coolhand undeclared" do
      described_class.install

      perform(Class.new.new)
      Coolhand.configuration.enabled = false
      perform(SummariseJob.new)

      expect(seen).to eq([nil, nil])
    end

    it "lets an explicit with_context inside the job win" do
      described_class.install
      explicit = -> { Coolhand.with_context(workload: { key: "Custom" }) { seen << Coolhand::DeclaredContext.current } }

      job_base.callbacks.first.call(SummariseJob.new, explicit)

      expect(seen.first).to include(workload: { key: "Custom" })
      expect(seen.first).not_to have_key(:template)
    end
  end

  describe "controller" do
    it "declares ControllerClass#action around the action" do
      Coolhand.configuration.auto_declare = [:controller]
      stub_const("UsersController", Class.new { def action_name = "show" })
      described_class.install

      controller_base.callbacks.first.call(UsersController.new, probe)

      expect(seen.first).to include(source: "rails", workload: { key: "UsersController#show" })
      expect(job_base.callbacks).to be_empty
    end
  end
end
