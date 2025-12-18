# frozen_string_literal: true

require "net/http"
require "uri"
require "faraday"
require "securerandom"

require_relative "ruby/version"
require_relative "ruby/configuration"
require_relative "ruby/collector"
require_relative "ruby/faraday_interceptor"
require_relative "ruby/net_http_interceptor"
require_relative "ruby/anthropic_interceptor"
require_relative "ruby/api_service"
require_relative "ruby/logger_service"
require_relative "ruby/feedback_service"

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

      Ruby::NetHttpInterceptor.patch!

      log "✅ Coolhand ready - will log OpenAI calls"
    end

    def capture
      unless block_given?
        log "❌ Coolhand Error: Method .capture requires block."
        return
      end

      Ruby::NetHttpInterceptor.patch!

      yield
    ensure
      Ruby::NetHttpInterceptor.unpatch!
    end

    # A simple logger that respects the 'silent' configuration option.
    def log(message)
      return if configuration.silent

      puts "COOLHAND: #{message}"
    end

    # Creates a new FeedbackService instance
    def feedback_service
      Ruby::FeedbackService.new
    end

    # Creates a new LoggerService instance
    def logger_service
      Ruby::LoggerService.new
    end

    def required_field?(value)
      return false if value.nil?
      return false if value.respond_to?(:empty?) && value.empty?
      return false if value.to_s.strip.empty?

      true
    end

    def current_request_id
      Thread.current[:coolhand_current_request_id]
    end
  end
end
