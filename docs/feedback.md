# Feedback API

Collect user feedback on LLM responses to improve your AI outputs. The Feedback API lets you capture sentiment ratings, explanations, and human-corrected outputs.

> **Frontend widget:** For browser-based feedback collection, see [coolhand-js](https://github.com/Coolhand-Labs/coolhand-js) — a lightweight JavaScript widget that captures actionable user feedback on any AI output.

## Basic Usage

```ruby
require 'coolhand'

feedback_service = Coolhand::FeedbackService.new

# Positive feedback linked by log ID (most reliable)
feedback_service.create_feedback(
  llm_request_log_id: 'abc123def456', # hashid from a prior response; a raw integer FK also still works
  sentiment: 'like',
  explanation: 'Clear and accurate answer.',
)

# Negative feedback with a human correction
feedback_service.create_feedback(
  original_output: 'The capital of France is London.',
  sentiment: 'dislike',
  revised_output: 'The capital of France is Paris.',
  explanation: 'Factually wrong.',
)
```

To link feedback to a specific request without storing the log ID, tag the request with your own id first:

```ruby
Coolhand.with_context(client_unique_id: 'order-42.1') do
  client.chat(...) # logged with client_unique_id 'order-42.1'
end

feedback_service.create_feedback(client_unique_id: 'order-42.1', sentiment: 'like')
```

Logs are sent in the background, so `create_feedback` holds the feedback until the log with that `client_unique_id` has finished sending (up to 5 seconds), then sends it. You don't need to call `Coolhand.flush` first. If that log's send failed (the failure is remembered for later `create_feedback` calls with that id, until a log with it is sent successfully), the feedback is not sent and `create_feedback` returns `nil`, because Coolhand never received the log. When several logs share an id, it waits for all of them and sends if any one was delivered. This ordering only covers logs queued in the same process; if you send feedback from a different process (a background job, say), make sure the log has been delivered first.

---

## Knowing whether feedback was delivered

By default `create_feedback` never raises: on any failure (non-2xx response, network error, missing API key) it logs the problem, unless `config.silent` is set, and returns `nil`. On success it returns the parsed response, so `nil` means the feedback was not stored (or, in `debug_mode`, was deliberately not sent).

Pass `raise_on_error: true` when you need to tell lost feedback from delivered feedback, for example to retry:

```ruby
begin
  feedback_service.create_feedback(client_unique_id: 'order-42.1', sentiment: 'like', raise_on_error: true)
rescue Coolhand::HttpError => e
  e.status # 422, 500, ...: the API's answer (e.body has the response body)
rescue Coolhand::Error => e
  # no API key, or a network error
end
```

Feedback is never retried automatically, because repeating the POST could store it twice; retrying is up to you. With a `client_unique_id`, `create_feedback` already waits for that log when it was queued in the same process, and with `raise_on_error: true` it raises a `Coolhand::Error` instead of returning `nil` when that log failed to send. A `client_unique_id` that matches no log yet is the common reason to retry feedback sent from another process: make sure the log was delivered first (`Coolhand.flush` in the process that logged it returns `false` when a queued log was not delivered: it failed to send after retrying transient errors, raised in its job, or was dropped from a full queue).

---

## Field Reference

All fields are optional. Use at least one **Matching Field** to link feedback to its originating LLM request.

### Matching Fields

These fields identify which LLM request the feedback refers to. Use the most specific one available.

| Field | Match type | Description |
|---|---|---|
| `llm_request_log_id` | Exact | Hashid returned when the original request was logged (a raw integer FK is also still accepted for backward compatibility). Most reliable. |
| `llm_provider_unique_id` | Exact | The provider's own request ID (e.g. `x-request-id` from Anthropic or OpenAI). |
| `client_unique_id` | Exact | Your own identifier for the request. Stamp it on the log with [`Coolhand.with_context(client_unique_id:)`](declared_workloads.md#linking-feedback-to-a-request), then pass the same value here. |
| `original_output` | Fuzzy | The raw text the LLM produced. Used for fuzzy matching when no ID is available — less reliable. |

### Quality Signals

| Field | Signal strength | Description |
|---|---|---|
| `revised_output` | ⭐ Best | The human-corrected version of the LLM output. Highest-value signal for quality improvement. |
| `explanation` | Medium | Free-text reason the response was good or bad. |
| `sentiment` | Low–Medium | `"like"`, `"dislike"`, or `"neutral"`. **Preferred** over the deprecated `like` boolean. |
| `like` | Low (deprecated) | Boolean: `true` = like, `false` = dislike. Auto-converted to `sentiment` before submission. Use `sentiment` instead. |

### Attribution Fields

| Field | Description |
|---|---|
| `creator_unique_id` | ID of the user providing feedback (for per-user quality tracking). |
| `creator_type` | Who submitted the feedback: `"human"`, `"agent"`, or `"unknown"`. |
| `workload_hashid` | Associate feedback with a specific workload in the Coolhand dashboard. |

---

## Sentiment Values

| Value | Meaning |
|---|---|
| `"like"` | The response was helpful / correct |
| `"dislike"` | The response was unhelpful / wrong |
| `"neutral"` | Neither good nor bad (e.g. factual but irrelevant) |

The deprecated `like: bool` field is still accepted and automatically converted:

| `like` (bool) | Equivalent `sentiment` |
|---|---|
| `true` | `"like"` |
| `false` | `"dislike"` |
