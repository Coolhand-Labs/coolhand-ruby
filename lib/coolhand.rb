# frozen_string_literal: true

require "net/http"
require "uri"
require "faraday"
require "securerandom"

require_relative "coolhand/version"
require_relative "coolhand/configuration"
require_relative "coolhand/collector"
require_relative "coolhand/api_service"
require_relative "coolhand/base_interceptor"
require_relative "coolhand/faraday_interceptor"
require_relative "coolhand/anthropic_interceptor"
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

    # Check if Anthropic gem is loaded
    def anthropic_gem_loaded?
      defined?(Anthropic)
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

      # Apply the Faraday patch (needed for ruby-anthropic and other Faraday-based gems)
      FaradayInterceptor.patch!

      # Conditionally patch the official Anthropic gem if it's loaded
      if anthropic_gem_loaded?
        if defined?(Anthropic::Internal)
          # Official anthropic gem - patch the AnthropicInterceptor for Net::HTTP requests
          AnthropicInterceptor.patch!
          log "✅ Coolhand ready - will log OpenAI and Anthropic (official gem) calls"
        else
          # ruby-anthropic gem uses Faraday, so FaradayInterceptor is sufficient
          log "✅ Coolhand ready - will log OpenAI and Anthropic (ruby-anthropic via Faraday) calls"
        end
      else
        log "✅ Coolhand ready - will log OpenAI calls"
      end
    end

    def capture
      unless block_given?
        log "❌ Coolhand Error: Method .capture requires block."
        return
      end

      # Patch both interceptors for capture mode
      FaradayInterceptor.patch!
      AnthropicInterceptor.patch! if anthropic_gem_loaded?

      yield
    ensure
      FaradayInterceptor.unpatch!
      AnthropicInterceptor.unpatch! if anthropic_gem_loaded?
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
