# frozen_string_literal: true

module Coolhand
  # Loaded by lib/coolhand.rb only when Rails is present, so the gem keeps no Rails dependency.
  class Railtie < ::Rails::Railtie
    # After the app's initializers, so `config.auto_declare` has been set by `Coolhand.configure`.
    config.after_initialize do
      Coolhand::RailsAutoDeclare.install
    end
  end
end
