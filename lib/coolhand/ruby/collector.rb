# frozen_string_literal: true

module Coolhand
  module Ruby
    # Utility for generating collector identification string
    module Collector
      COLLECTION_METHODS = %w[manual auto-monitor].freeze

      class << self
        # Gets the collector identification string
        # Format: "coolhand-ruby-X.Y.Z" or "coolhand-ruby-X.Y.Z-method"
        # @param method [String, nil] Optional collection method suffix
        # @return [String] Collector string identifying this SDK version and collection method
        def get_collector_string(method = nil)
          base = "coolhand-ruby-#{VERSION}"
          method && COLLECTION_METHODS.include?(method) ? "#{base}-#{method}" : base
        end
      end
    end
  end
end
