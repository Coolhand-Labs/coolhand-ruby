# Feedback API

Collect user feedback on LLM responses to improve your AI outputs. The Feedback API lets you capture sentiment ratings, explanations, and human-corrected outputs.

> **Frontend widget:** For browser-based feedback collection, see [coolhand-js](https://github.com/Coolhand-Labs/coolhand-js) — a lightweight JavaScript widget that captures actionable user feedback on any AI output.

## Basic Usage

```ruby
require 'coolhand'

feedback_service = Coolhand::FeedbackService.new(Coolhand.configuration)

# Positive feedback linked by log ID (most reliable)
feedback_service.create_feedback(
  llm_request_log_id: 12345,
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

---

## Field Reference

All fields are optional. Use at least one **Matching Field** to link feedback to its originating LLM request.

### Matching Fields

These fields identify which LLM request the feedback refers to. Use the most specific one available.

| Field | Match type | Description |
|---|---|---|
| `llm_request_log_id` | Exact | Coolhand log ID returned when the original request was logged. Most reliable. |
| `llm_provider_unique_id` | Exact | The provider's own request ID (e.g. `x-request-id` from Anthropic or OpenAI). |
| `client_unique_id` | Exact | Your own internal identifier for the request (e.g. a database row ID). |
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
