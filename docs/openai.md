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
