# frozen_string_literal: true

module Coolhand
  # Redacts credential-bearing values from request and response bodies before they are sent to
  # Coolhand. Header and URL redaction live in BaseInterceptor; this covers the body.
  module BodyRedactor
    module_function

    # Body keys whose *string* value is a credential in any request or response body, matched
    # exactly (never as a substring) against the key lowercased with `_`, `-` and spaces removed,
    # so `api_key`, `apiKey`, `API-Key` and `apikey` all match. Only String leaves are redacted:
    # a JSON Schema property named `api_key` has a Hash value and is left alone, as is a numeric
    # `usage.total_tokens`. Covers OpenAI Responses/Realtime MCP `tools[].authorization`, Anthropic
    # `mcp_servers[].authorization_token`, and the legacy Realtime `client_secret` string form.
    CREDENTIAL_BODY_KEYS = %w[
      authorization authorizationtoken accesstoken refreshtoken idtoken
      apikey clientsecret privatekey secretkey password
    ].freeze

    def redact(body)
      return body unless body.is_a?(Hash) || body.is_a?(Array)

      redact_body_node(body, 0)
    end

    def redact_body_node(node, depth)
      return BaseInterceptor::REDACTED if depth > BaseInterceptor::MAX_BODY_DEPTH

      case node
      when Hash then redact_body_hash(node, depth)
      when Array then node.map { |v| redact_body_node(v, depth + 1) }
      else node
      end
    end

    # `secret_object` marks the object under a `client_secret` key (legacy Realtime
    # `{value, expires_at}`), whose `value` is the ephemeral key.
    def redact_body_hash(hash, depth, secret_object: false)
      context = { secret_value: secret_object || ephemeral_secret?(hash), mcp: mcp_tool?(hash) }
      hash.each_with_object({}) do |(key, value), acc|
        acc[key] = redact_body_entry(normalize_body_key(key), value, depth, context)
      end
    end

    def redact_body_entry(name, value, depth, context)
      if name == "datasources"
        BaseInterceptor.redact_sensitive_body_values(value, depth + 1)
      elsif value.is_a?(String) && redact_string_leaf?(name, context)
        BaseInterceptor::REDACTED
      elsif name == "headers" && context[:mcp]
        redact_header_values(value)
      elsif name == "clientsecret" && value.is_a?(Hash)
        redact_body_hash(value, depth + 1, secret_object: true)
      else
        redact_body_node(value, depth + 1)
      end
    end

    def redact_string_leaf?(name, context)
      CREDENTIAL_BODY_KEYS.include?(name) || (context[:secret_value] && name == "value")
    end

    def normalize_body_key(key)
      key.to_s.delete("_ -").downcase # trailing "-" is a literal hyphen, not a range
    end

    # Realtime GA `POST /v1/realtime/client_secrets` returns `{"value": "ek_...", "expires_at": 123,
    # "session": {...}}`. `value` alone is far too generic to redact by name, so require the
    # numeric `expires_at` that accompanies it.
    def ephemeral_secret?(hash)
      hash_value(hash, "value").is_a?(String) && hash_value(hash, "expires_at").is_a?(Numeric)
    end

    # An OpenAI remote-MCP tool (`type: "mcp"`, or any entry carrying a `server_url`), whose
    # `headers` map holds authentication headers. A bare `headers` key elsewhere is left alone.
    def mcp_tool?(hash)
      hash_value(hash, "type") == "mcp" || !hash_value(hash, "server_url").nil?
    end

    def redact_header_values(headers)
      return headers unless headers.is_a?(Hash)

      headers.transform_values { |v| v.is_a?(String) ? BaseInterceptor::REDACTED : v }
    end

    def hash_value(hash, name)
      hash.fetch(name) { hash[name.to_sym] }
    end
  end
end
