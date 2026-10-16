# frozen_string_literal: true

module Coolhand
  # Opt-in (`config.auto_declare`) declaration of the workload and template for LLM calls made from a
  # Rails job or controller action, keyed "JobClass#perform" / "ControllerClass#action". Installed from
  # {Railtie} once the app has configured Coolhand. Kept free of any Rails require: it only touches
  # ActiveSupport and ActiveJob when a target is enabled, and only through their own load hooks.
  module RailsAutoDeclare
    SOURCE = "rails"
    TARGETS = %i[active_job controller].freeze

    @installed = []

    module_function

    def install(targets = Coolhand.configuration.auto_declare)
      TARGETS.each do |target|
        next unless targets.include?(target) && !@installed.include?(target)

        @installed << target
        send(:"hook_#{target}")
      end
    end

    def hook_active_job
      ActiveSupport.on_load(:active_job) do
        around_perform do |job, block|
          Coolhand::RailsAutoDeclare.declare(job.class, "perform", &block)
        end
      end
    end

    def hook_controller
      ActiveSupport.on_load(:action_controller) do
        around_action do |controller, block|
          Coolhand::RailsAutoDeclare.declare(controller.class, controller.action_name, &block)
        end
      end
    end

    # Runs the block inside a declared context. Anonymous classes have no stable key, so they are left
    # undeclared rather than named after an object id.
    def declare(klass, method_name, &block)
      return yield if klass.name.nil? || !Coolhand.configuration.enabled

      key = "#{klass.name}##{method_name}"
      Coolhand.with_context(source: SOURCE, workload: { key: key }, template: { key: key }, &block)
    end

    # Testing-only: forget which targets were hooked.
    def reset!
      @installed.clear
    end
  end
end
