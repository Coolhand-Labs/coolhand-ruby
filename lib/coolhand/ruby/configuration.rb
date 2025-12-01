# frozen_string_literal: true

module Coolhand
  # Handles all configuration settings for the gem.
  class Configuration
    attr_accessor :api_key, :environment, :silent
    attr_reader :intercept_addresses

    def initialize
      # Set defaults
      @environment = "production"
      @api_key = nil
      @silent = false
      @intercept_addresses = ["api.openai.com", "api.anthropic.com", "api.elevenlabs.io"]
    end

    # Custom setter that preserves defaults when nil/empty array is provided
    def intercept_addresses=(value)
      return if value.nil? || (value.is_a?(Array) && value.empty?)

      @intercept_addresses = value.is_a?(Array) ? value : [value]
    end

    def validate!
      # Validate API Key after configuration
      if api_key.nil?
        Coolhand.log "❌ Coolhand Error: API Key is required. Please set it in the configuration."
        raise Error, "API Key is required"
      end

      # Validate intercept_addresses after configuration
      if intercept_addresses.nil? || intercept_addresses.empty?
        Coolhand.log "❌ Coolhand Error: Intercept addresses cannot be empty. Please set it in the configuration."
        raise Error, "Intercept addresses cannot be empty"
      end
    end
  end
end
