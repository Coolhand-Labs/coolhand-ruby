# frozen_string_literal: true

module Coolhand
  # Handles all configuration settings for the gem.
  class Configuration
    attr_accessor :api_key, :log_model, :api_endpoint, :environment, :silent, :openai_address

    def initialize
      @environment = ENV.fetch('COOLHAND_ENV', 'development')
      @log_model = ENV.fetch('COOLHAND_MODEL', nil)
      @api_endpoint = ENV.fetch('COOLHAND_API_ENDPOINT', nil)
      @api_key = ENV.fetch('COOLHAND_API_KEY', nil)
      @silent = ENV.fetch('COOLHAND_SILENT', false)
      @openai_address = ENV.fetch('COOLHAND_OPENAI_ADDRESS', false)
    end
  end
end
