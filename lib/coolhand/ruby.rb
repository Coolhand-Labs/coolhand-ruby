# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'thread'

require_relative "ruby/version"
require_relative "ruby/configuration"
require_relative "ruby/interceptor"
require_relative "ruby/logger"
require_relative "ruby/log_formatter"
require_relative "ruby/stats"

# The main module for the Coolhand gem.
# It provides the configuration interface and initializes the patching.
module Coolhand
  class Error < StandardError; end

  # Class-level instance variables to hold the configuration
  @configuration = Configuration.new

  class << self
    attr_reader :configuration

    # Provides a block to configure the gem.
    #
    # Example:
    #   Coolhand.configure do |config|
    #     config.environment = 'development'
    #     config.log_model = 'LlmRequestLog'
    #     config.api_endpoint = 'https://api.openai.com'
    #     config.silent = false
    #     config.api_key = "xxx-yyy-zzz"
    #     config.openai_address = "openai.com"
    #   end
    def configure
      yield(configuration)

      # Validate API Key after configuration
      unless configuration.api_key.present?
        $stderr.puts '❌ Coolhand Error: API Key is required. Please set it in the configuration.'
        raise Error, 'API Key is required'
      end

      # Validate Log Model after configuration
      unless configuration.log_model.present?
        $stderr.puts '❌ Coolhand Error: Log Model is required. Please set it in the configuration.'
        raise Error, 'Log Model is required'
      end

      # Validate API Endpoint after configuration
      unless configuration.api_endpoint.present?
        $stderr.puts '❌ Coolhand Error: API Endpoint is required. Please set it in the configuration.'
        raise Error, 'API Endpoint is required'
      end

      # Apply the patch after configuration is set
      # Interceptor.patch!
      # log "✅ Coolhand ready - will log OpenAI calls to #{configuration.api_endpoint}"
    end

    def capture
      unless block_given?
        $stderr.puts '❌ Coolhand Error: Method .capture requires block.'
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
  end
end