# frozen_string_literal: true

require "yaml"
require "uri"

module Coolhand
  # Handles all configuration settings for the gem.
  class Configuration
    DEFAULT_EXCLUDE_API_PATTERNS = YAML.load_file(
      File.join(__dir__, "default_exclude_api_patterns.yml")
    ).freeze

    DEFAULT_INTERCEPT_ADDRESSES = YAML.load_file(
      File.join(__dir__, "default_intercept_addresses.yml")
    ).freeze

    BASE_URL_ERROR_MSG = "base_url must use https:// (or http://localhost / http://127.0.0.1 for local dev)"
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    attr_accessor :api_key, :environment, :silent, :debug_mode, :capture, :exclude_api_patterns, :enabled
    attr_reader :intercept_addresses, :base_url

    def initialize
      # Set defaults
      @environment = "production"
      @api_key = nil
      @silent = false
      @intercept_addresses = DEFAULT_INTERCEPT_ADDRESSES.dup
      self.base_url = "https://coolhandlabs.com/api"
      @debug_mode = false
      @capture = true
      @exclude_api_patterns = DEFAULT_EXCLUDE_API_PATTERNS.dup
      @enabled = true
    end

    # Custom setter that preserves defaults when nil/empty array is provided
    def intercept_addresses=(value)
      return if value.nil? || (value.is_a?(Array) && value.empty?)

      @intercept_addresses = value.is_a?(Array) ? value : [value]
    end

    def base_url=(value)
      stripped = value&.sub(%r{/+\z}, "")
      raise Error, BASE_URL_ERROR_MSG unless stripped.nil? || valid_base_url?(stripped)

      @base_url = stripped
    end

    def validate!
      # Validate intercept_addresses after configuration
      if intercept_addresses.nil? || intercept_addresses.empty?
        Coolhand.log "❌ Coolhand Error: Intercept addresses cannot be empty. Please set it in the configuration."
        raise Error, "Intercept addresses cannot be empty"
      end

      unless valid_base_url?(base_url)
        Coolhand.log "❌ Coolhand Error: #{BASE_URL_ERROR_MSG}"
        raise Error, BASE_URL_ERROR_MSG
      end
    end

    private

    def valid_base_url?(url)
      return false if url.nil? || url.empty?

      parsed = URI.parse(url)
      host = parsed.hostname&.downcase

      return false if host.nil? || host.empty?
      return true if parsed.scheme == "https"

      parsed.scheme == "http" && LOOPBACK_HOSTS.include?(host)
    rescue URI::InvalidURIError
      false
    end
  end
end
