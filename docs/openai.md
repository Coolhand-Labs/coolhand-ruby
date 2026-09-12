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

`intercept_batch_request` already validates the webhook and, for `batch.completed`/`batch.failed`/`batch.expired`/`batch.cancelled` events, calls `Coolhand::OpenAi::BatchResultProcessor` **synchronously**, inline in the `before_action` — that part requires no code in your controller action. It downloads two JSONL files from OpenAI and sends one request log per batch item, so a large batch can take long enough to trip your webhook endpoint's timeout (and OpenAI's retry behavior); consider that when sizing batches. The example below shows a controller action doing additional, app-specific work on top of that (e.g. updating your own `BatchApiRequest` record and enqueuing your own background job), which is optional.

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

## Replay protection

`Coolhand::OpenAi::WebhookValidator` rejects requests whose `webhook-timestamp` is more than **300 seconds** away from the current time, and rejects a `webhook-id` it has already seen within that window — this prevents a captured request (from a log aggregator, APM trace, or proxy log) from being replayed to re-trigger `Coolhand::OpenAi::BatchResultProcessor`.

Both are configurable:

```ruby
Coolhand.configure do |config|
  # Widen or narrow the timestamp tolerance window (seconds). Default: 300.
  config.webhook_replay_tolerance_seconds = 600
end
```

The default `webhook-id` dedup store is in-memory and per-process, so it only protects a single process — replays across multiple app processes/dynos within the tolerance window aren't caught by default. If you run more than one process, supply your own store via `config.webhook_id_store`; any object responding to `claim!(id, ttl_seconds)` works, e.g. one backed by `Rails.cache`. `claim!` must atomically check-and-record the id in one operation (not a separate read then write) — otherwise two requests racing on the same id can both "win" — so lean on your cache backend's compare-and-set primitive (`unless_exist:` below maps to Redis `SET NX` when using `RedisCacheStore`):

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

Note: the `webhook-id` is claimed as soon as the signature and timestamp are confirmed valid — before your controller's `process_event` runs. If something downstream fails before the batch is actually handled (e.g. an unexpectedly-shaped payload), a same-id retry within the tolerance window will be rejected as a replay rather than reprocessed.
