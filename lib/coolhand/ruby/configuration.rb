# frozen_string_literal: true

module Coolhand
  # Handles all configuration settings for the gem.
  class Configuration
    attr_accessor :api_key, :api_endpoint, :environment, :silent, :intercept_addresses

    def initialize
      @environment = ENV.fetch("COOLHAND_ENV", "development")
      @api_endpoint = ENV.fetch("COOLHAND_API_ENDPOINT", "https://coolhand.io/api/v2/llm_request_logs")
      @api_key = ENV.fetch("COOLHAND_API_KEY", nil)
      @silent = ENV.fetch("COOLHAND_SILENT", false)
      @intercept_addresses = ENV.fetch("COOLHAND_INTERCEPT_ADDRESSES", [])
    end

    def validate!
      # Validate API Key after configuration
      if api_key.nil?
        Coolhand.log "❌ Coolhand Error: API Key is required. Please set it in the configuration."
        raise Error, "API Key is required"
      end

      # Validate API Endpoint after configuration
      if api_endpoint.nil?
        Coolhand.log "❌ Coolhand Error: API Endpoint is required. Please set it in the configuration."
        raise Error, "API Endpoint is required"
      end

      # Validate API Endpoint after configuration
      if intercept_addresses.nil?
        Coolhand.log "❌ Coolhand Error: Intercept Address is required. Please set it in the configuration."
        raise Error, "Intercept Address is required"
      end
    end
  end
end
