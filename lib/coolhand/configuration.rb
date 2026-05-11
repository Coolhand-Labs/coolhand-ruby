# frozen_string_literal: true

require "yaml"
require "uri"

module Coolhand
  # Handles all configuration settings for the gem.
  class Configuration
    DEFAULT_EXCLUDE_API_PATTERNS = YAML.load_file(
      File.join(__dir__, "default_exclude_api_patterns.yml")
    ).freeze

    attr_accessor :api_key, :environment, :silent, :debug_mode, :capture, :exclude_api_patterns
    attr_reader :intercept_addresses, :base_url

    def initialize
      # Set defaults
      @environment = "production"
      @api_key = nil
      @silent = false
      @intercept_addresses = ["api.openai.com", "api.anthropic.com", "api.elevenlabs.io",
                              "generativelanguage.googleapis.com",
                              ":generateContent", ":streamGenerateContent"]
      self.base_url = "https://coolhandlabs.com/api"
      @debug_mode = false
      @capture = true
      @exclude_api_patterns = DEFAULT_EXCLUDE_API_PATTERNS.dup
    end

    # Custom setter that preserves defaults when nil/empty array is provided
    def intercept_addresses=(value)
      return if value.nil? || (value.is_a?(Array) && value.empty?)

      @intercept_addresses = value.is_a?(Array) ? value : [value]
    end

    def base_url=(value)
      @base_url = value&.sub(/\/+\z/, "")
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

      unless valid_base_url?(base_url)
        Coolhand.log "❌ Coolhand Error: base_url must use https:// (or http://localhost / http://127.0.0.1 for local dev)."
        raise Error, "base_url must use https:// (or http://localhost / http://127.0.0.1 for local dev)"
      end
    end

    private

    def valid_base_url?(url)
      return false if url.nil? || url.empty?

      parsed = URI.parse(url)
      return true if parsed.scheme == "https"

      parsed.scheme == "http" && (parsed.host == "localhost" || parsed.host == "127.0.0.1")
    rescue URI::InvalidURIError
      false
    end
  end
end
