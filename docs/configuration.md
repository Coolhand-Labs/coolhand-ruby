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

## Debug Mode

`config.debug_mode` is a local-development aid: it prints every prepared payload to the console instead of sending it to the Coolhand API (or your self-hosted `base_url`), so you can inspect exactly what would be logged without an API key or network access.

```ruby
Coolhand.configure do |config|
  config.debug_mode = Rails.env.development?
end
```

**What changes when `debug_mode` is `true`:**
- No HTTP request is made — `create_log`, `create_feedback`, and `send_llm_request_log` all return `nil` and print the payload via `JSON.pretty_generate` instead.
- Capture is forced on for every request, including inside a `Coolhand.without_capture` block and when `config.capture = false`. This is intentional — debug mode is meant to show you everything, not respect capture suppression — so don't leave it enabled in an environment where you rely on `without_capture` to keep specific calls out of the logs.
- Header and URL sanitization (`[REDACTED]` API keys/tokens, redacted `key=`/`token=` query params) still applies to the printed payload, exactly as it would to a real request.

Because it forces capture unconditionally and prints full request/response bodies to the console, only enable `debug_mode` in development — never in production or in an environment handling real user data.

## Request Body Capture Limits

To avoid holding large uploads (batch JSONL files, fine-tune corpora, audio for transcription) in memory and shipping them to Coolhand in full, `config.max_captured_body_bytes` caps how much of a request body gets captured:

```ruby
Coolhand.configure do |config|
  config.max_captured_body_bytes = 2_000_000 # default: 1_000_000 (1 MB)
end
```

**What happens at the limits:**
- A request body whose `Content-Type` doesn't look like JSON (e.g. `multipart/form-data`, `audio/mpeg`) is never read into memory for capture — the log entry gets a placeholder (`{"_coolhand_capture_skipped" => "non_json_content_type", ...}`) instead of the body. This is intentional: an opaque binary blob isn't human/LLM-readable in Coolhand's UI anyway.
- A JSON (or content-type-unset) body larger than the configured limit is replaced with a placeholder (`{"_coolhand_capture_skipped" => "body_too_large", ...}`) instead of being logged in full.

In both cases, only the *captured log entry* is affected — the real request to the LLM provider always sends the complete, untruncated body.

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
