# Advanced Configuration

## Self-Hosted Deployments

For compliance, data-residency, or cost reasons you can run your own Coolhand-compatible endpoint and point the SDK at it via `config.base_url`:

```ruby
Coolhand.configure do |config|
  config.api_key  = ENV['COOLHAND_API_KEY']
  config.base_url = ENV['COOLHAND_BASE_URL']  # e.g. "https://coolhand.internal.example.com/api"
end
```

When `base_url` is unset the SDK defaults to `https://coolhandlabs.com/api` and behaviour is unchanged.

**URL validation rules:**
- Any `https://` URL — required for production use
- `http://localhost` or `http://127.0.0.1` — accepted for local development only
- Non-HTTPS remote URLs are rejected: the SDK raises `Coolhand::Error` at configure time if `base_url` is set to a plain `http://` URL pointing at a non-localhost host

**Trailing slashes** are stripped automatically, so `"https://example.com/api/"` and `"https://example.com/api"` are equivalent.

---

## Custom Intercept Addresses

By default Coolhand captures requests to a built-in list of LLM API hosts (OpenAI, Anthropic, Google Gemini, ElevenLabs, GitHub Models, and more). To capture a custom endpoint — an internal proxy, a self-hosted model server, or a third-party gateway — override `intercept_addresses`:

```ruby
Coolhand.configure do |config|
  config.api_key = ENV['COOLHAND_API_KEY']
  config.intercept_addresses = [
    'my-llm-proxy.internal',
    'api.openai.com',      # include the defaults you still want
    'api.anthropic.com',
  ]
end
```

Setting `intercept_addresses` **replaces** the default list entirely, so include any default hosts you still need.

The default list can be found in `Coolhand::Configuration::DEFAULT_INTERCEPT_ADDRESSES`.
