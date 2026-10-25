# OpenAI Batch Webhook Handler

Automatically handle OpenAI batch event logs (`batch.completed`, `batch.failed`, `batch.expired`, `batch.cancelled`) by intercepting webhook requests and logging completed batch results to Coolhand.

For monitoring regular (non-batch) OpenAI API calls, see the [OpenAI client example](../README.md#with-openai-ruby-client) in the main README — no extra setup is required beyond `Coolhand.configure`.

Requires Rails — `Coolhand::WebhookInterceptor` and `Coolhand::OpenAi::BatchResultProcessor` log via `Rails.logger` internally. `config.capture = false` and `Coolhand.without_capture` do not suppress these logs: unlike the passive Net::HTTP interceptor, `intercept_batch_request` dispatching to `Coolhand::OpenAi::BatchResultProcessor` is an explicit, deliberate act, so it always sends.

## Usage

- Add the `openai` gem to your Gemfile — `Coolhand::OpenAi::BatchResultProcessor` needs it to download batch result files.
- Include the interceptor in your controller: `include Coolhand::WebhookInterceptor`
- Add the `before_action` to validate and populate the `@validator` payload: `before_action :intercept_batch_request, only: :openai`
- Ensure you skip CSRF for the webhook endpoint: `skip_before_action :verify_authenticity_token`
- Override the `webhook_secret` method to return your OpenAI webhook secret

`intercept_batch_request` already validates the webhook and, for `batch.completed`/`batch.failed`/`batch.expired`/`batch.cancelled` events, calls `Coolhand::OpenAi::BatchResultProcessor` — that part requires no code in your controller action. The batch's status is checked inline in the `before_action`, but for a completed batch the two JSONL file downloads and the one-request-log-per-item sends run on Coolhand's [background log thread](configuration.md#asynchronous-logging), so a large batch doesn't hold up your webhook response. (With `config.async_logging = false` this all runs inline, and a large batch can trip your webhook endpoint's timeout and OpenAI's retry behavior.) The example below shows a controller action doing additional, app-specific work on top of that (e.g. updating your own `BatchApiRequest` record and enqueuing your own background job), which is optional.

## Minimal example

Only the key lines are shown — wire this into your own controller and background job setup.

```ruby
# app/controllers/webhooks/batch_api_requests_controller.rb
# ...existing code...
include Coolhand::WebhookInterceptor

skip_before_action :verify_authenticity_token
before_action :intercept_batch_request, only: :openai

def openai
  event = JSON.parse(@validator.payload)
  case event["type"]
  when "batch.completed", "batch.failed", "batch.expired", "batch.cancelled"
    batch_id = event.dig("data", "id")
    batch_request = BatchApiRequest.find_by(provider: "openai", provider_batch_id: batch_id)

    if batch_request
      MyApp::BatchResultJob.perform_async(batch_request.id)
      Rails.logger.info("Queued batch result processing for BatchApiRequest #{batch_request.id}")
    else
      Rails.logger.warn("Could not find BatchApiRequest for OpenAI batch ID: #{batch_id}")
    end
  else
    Rails.logger.info("Unhandled OpenAI webhook event type: #{event["type"]}")
  end

  head :ok
rescue JSON::ParserError
  head :bad_request
rescue StandardError => e
  Rails.logger.error("OpenAI webhook error: #{e.message}")
  head :internal_server_error
end

def webhook_secret
  Rails.application.credentials.openai_webhook_secret
end
# ...existing code...
```

## What gets logged for a completed batch

Each batch item is logged with `source_api: "openai"` and the `model` from the item's request body (falling back to the response body). Batch input files use relative URLs such as `/v1/chat/completions`; these are logged as `https://api.openai.com/v1/chat/completions` (the host is not configurable, so Azure OpenAI or proxy batches are logged with that host too). The batch's `in_progress_at` and `completed_at` timestamps become each log's start and completion times; if OpenAI reports either as missing, the whole batch is skipped with an error in `Rails.logger` rather than logged with bogus times. If `completed_at` is earlier than `in_progress_at`, a warning is logged and `duration_ms` is clamped to 0.

The batch ID from the webhook payload and the batch's input/output file IDs are used in calls to the OpenAI API with your `OPENAI_API_KEY`, so they are format-checked first (`batch_...` and `file-...`/`file_...`, letters, digits, `_` and `-` only). An event or batch whose IDs don't match is ignored with an error in `Rails.logger`.

## Signature header and secret rotation

The `webhook-signature` header may carry several space-separated signatures (`v1,sigA v1,sigB`), as senders produce while a webhook secret is being rotated. `Coolhand::OpenAi::WebhookValidator` accepts the request if any `v1,` entry matches your secret, comparing each in constant time and ignoring entries with any other version prefix. The timestamp and replay checks below still run, and only after a signature matches.

## Local development and testing

Signature headers (`webhook-signature`, `webhook-timestamp`, `webhook-id`) are required whenever a webhook secret is configured, in every `Rails.env`, including `development` and `test`. A request missing any of them is rejected, so your controller responds with 401. Earlier versions let unsigned requests through in development and test, which meant an app running with `RAILS_ENV=development` on a reachable host accepted forged webhooks.

Signature verification is skipped (with a logged warning) only when no secret is configured at all, and only in `development` and `test`. Every other environment rejects the request.

If you post unsigned test payloads to a local app that has a secret set, pick one of these:

- **Sign the test payload** with the same secret:

  ```ruby
  require "openssl"
  require "base64"
  require "json"
  require "securerandom"

  # Same key handling as the validator: a `whsec_` secret is base64-decoded, anything else is used as-is.
  secret = ENV.fetch("OPENAI_WEBHOOK_SECRET")
  secret_bytes = secret.start_with?("whsec_") ? Base64.strict_decode64(secret.delete_prefix("whsec_")) : secret
  id = "wh_local_#{SecureRandom.hex(4)}"
  timestamp = Time.now.to_i.to_s
  body = { type: "batch.completed", data: { id: "batch_123" } }.to_json
  signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret_bytes, "#{id}.#{timestamp}.#{body}"))

  # Send `body` with these headers:
  #   webhook-id: <id>
  #   webhook-timestamp: <timestamp>
  #   webhook-signature: v1,<signature>
  ```

- **Leave the secret unset in development**, for example have `webhook_secret` return `nil` unless `Rails.env.production?`.
- **Replay a real delivery** to your local app through a tunnel.

## Replay protection

`Coolhand::OpenAi::WebhookValidator` rejects requests whose `webhook-timestamp` is more than **300 seconds** away from the current time, and rejects a `webhook-id` it has already seen within twice that window (a request dated at the edge of the tolerance stays fresh for up to two tolerances, so the id is remembered at least as long) — this prevents a captured request (from a log aggregator, APM trace, or proxy log) from being replayed to re-trigger `Coolhand::OpenAi::BatchResultProcessor`.

Both are configurable:

```ruby
Coolhand.configure do |config|
  # Widen or narrow the timestamp tolerance window (seconds). Default: 300.
  config.webhook_replay_tolerance_seconds = 600
end
```

The default `webhook-id` dedup store is in-memory and per-process, so it only protects a single process — replays across multiple app processes/dynos within the replay-protection window aren't caught by default. If you run more than one process, supply your own store via `config.webhook_id_store`; any object responding to `claim!(id, ttl_seconds)` works (`ttl_seconds` is twice `webhook_replay_tolerance_seconds`), e.g. one backed by `Rails.cache`. `claim!` must atomically check-and-record the id in one operation (not a separate read then write) — otherwise two requests racing on the same id can both "win" — so lean on your cache backend's compare-and-set primitive (`unless_exist:` below maps to Redis `SET NX` when using `RedisCacheStore`):

```ruby
class RailsCacheWebhookIdStore
  # Returns true if this is the first time `id` has been claimed (the
  # write happened), false if it was already claimed within its TTL.
  def claim!(id, ttl_seconds)
    Rails.cache.write("coolhand:openai_webhook:#{id}", true, expires_in: ttl_seconds, unless_exist: true)
  end
end

Coolhand.configure do |config|
  config.webhook_id_store = RailsCacheWebhookIdStore.new
end
```

Note: the `webhook-id` is claimed as soon as the signature and timestamp are confirmed valid — before your controller's `process_event` runs. If something downstream raises (e.g. an error in your own `process_event` override, or an unexpectedly-shaped payload), the interceptor releases the claim before responding, so OpenAI's retry of the same `webhook-id` is processed rather than rejected as a replay. (`Coolhand::OpenAi::BatchResultProcessor` rescues and logs its own errors, and does its heavy work in the background, so this mainly matters for exceptions raised in your own code.)

Releasing is optional for custom stores: if your store also responds to `release!(id)`, it is called to forget the claim; a store that only implements `claim!` behaves as before and keeps the id claimed for its TTL even after a failure. To opt in, add `release!` to the store above:

```ruby
class RailsCacheWebhookIdStore
  def release!(id)
    Rails.cache.delete("coolhand:openai_webhook:#{id}")
  end
end
```
