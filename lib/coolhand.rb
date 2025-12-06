# frozen_string_literal: true

require "net/http"
require "uri"
require "faraday"
require "securerandom"

require_relative "coolhand/version"
require_relative "coolhand/configuration"
require_relative "coolhand/collector"
require_relative "coolhand/interceptor"
require_relative "coolhand/api_service"
require_relative "coolhand/logger_service"
require_relative "coolhand/feedback_service"

# The main module for the Coolhand gem.
# It provides the configuration interface and initializes the patching.
module Coolhand
  class Error < StandardError; end

  # Class-level instance variables to hold the configuration
  @configuration = Configuration.new

  class << self
    attr_reader :configuration

    # Reset configuration to defaults (mainly for testing)
    def reset_configuration!
      @configuration = Configuration.new
    end

    # Provides a block to configure the gem.
    #
    # Example:
    #   Coolhand.configure do |config|
    #     config.environment = 'development'
    #     config.silent = false
    #     config.api_key = "xxx-yyy-zzz"
    #     config.intercept_addresses = ["openai.com"]
    #   end
    def configure
      yield(configuration)

      configuration.validate!

      # Apply the patch after configuration is set
      Interceptor.patch!

      log "✅ Coolhand ready - will log OpenAI calls"
    end

    def capture
      unless block_given?
        log "❌ Coolhand Error: Method .capture requires block."
        return
      end

      Interceptor.patch!

      yield
    ensure
      Interceptor.unpatch!
    end

    # A simple logger that respects the 'silent' configuration option.
    def log(message)
      return if configuration.silent

      puts "COOLHAND: #{message}"
    end

    # Creates a new FeedbackService instance
    def feedback_service
      FeedbackService.new
    end

    # Creates a new LoggerService instance
    def logger_service
      LoggerService.new
    end

    def required_field?(value)
      return false if value.nil?
      return false if value.respond_to?(:empty?) && value.empty?
      return false if value.to_s.strip.empty?

      true
    end
  end
end
