# frozen_string_literal: true

require "uri"
require "yaml"

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
      @base_url = "https://coolhandlabs.com/api"
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
      @base_url = value.to_s.gsub(%r{/+\z}, "")
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

      validate_base_url!
    end

    LOCAL_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

    private

    def validate_base_url!
      url = base_url.to_s
      return if url.start_with?("https://")

      if url.start_with?("http://")
        host = begin
          URI.parse(url).host.to_s.downcase
        rescue URI::InvalidURIError
          Coolhand.log "❌ Coolhand Error: base_url is not a valid URL. Got: #{url}"
          raise Error, "base_url is not a valid URL"
        end
        return if LOCAL_HOSTS.include?(host)

        Coolhand.log "❌ Coolhand Error: base_url must use https:// for non-local hosts. Got: #{url}"
        raise Error, "base_url must use https:// for non-local hosts"
      end

      Coolhand.log "❌ Coolhand Error: base_url has an invalid scheme. Got: #{url}"
      raise Error, "base_url has an invalid scheme"
    end
  end
end
