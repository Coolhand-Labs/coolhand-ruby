# frozen_string_literal: true

require "uri"
require "faraday"
require "securerandom"
require "json"

require_relative "coolhand/version"
require_relative "coolhand/configuration"
require_relative "coolhand/collector"
require_relative "coolhand/base_interceptor"
require_relative "coolhand/net_http_interceptor"
require_relative "coolhand/api_service"
require_relative "coolhand/logger_service"
require_relative "coolhand/feedback_service"
require_relative "coolhand/open_ai/webhook_validator"
require_relative "coolhand/open_ai/batch_result_processor"
require_relative "coolhand/vertex/batch_result_processor"
require_relative "coolhand/webhook_interceptor"

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
    #     config.intercept_addresses = ["openai.com", "api.anthropic.com"]
    #   end
    def configure
      yield(configuration)

      configuration.validate!

      NetHttpInterceptor.patch!

      log "✅ Coolhand ready - will log OpenAI calls"
    end

    def capture
      unless block_given?
        log "❌ Coolhand Error: Method .capture requires block."
        return
      end

      patched = NetHttpInterceptor.patched?

      NetHttpInterceptor.patch!

      yield
    ensure
      NetHttpInterceptor.unpatch! unless patched
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
