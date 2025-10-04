# frozen_string_literal: true

module Coolhand
  # Utility methods for parsing and sanitizing data before logging.
  module LogFormatter
    def self.parse_json(string)
      return nil unless string && !string.empty?
      JSON.parse(string)
    rescue JSON::ParserError
      string # Return the raw string if it's not valid JSON
    end

    def self.sanitize_headers(headers)
      # Net::HTTP returns header values as arrays, we flatten them for simplicity
      sanitized = headers.transform_values(&:first)

      if sanitized['authorization']
        sanitized['authorization'] = sanitized['authorization'].gsub(/Bearer .+/, 'Bearer [REDACTED]')
      end
      if sanitized['openai-api-key']
        sanitized['openai-api-key'] = '[REDACTED]'
      end
      if sanitized['api-key']
        sanitized['api-key'] = '[REDACTED]'
      end

      sanitized
    end
  end
end