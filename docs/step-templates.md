# Reading Step Templates (List + Get)

`Coolhand::StepTemplateService` reads the step templates Coolhand detects in captured agent sessions.
A `prompt_step` matches a user prompt such as a slash command; a `tool_step` matches tool usage. It
wraps two read-only endpoints; there are no write endpoints:

| method | endpoint |
|---|---|
| `list_step_templates` | `GET /api/v2/step_templates` |
| `get_step_template` | `GET /api/v2/step_templates/{id}` |

Both require your **private** API key; the public key returns `401`. The client is derived from the
key, so there is no `client_id` keyword.

```ruby
require "coolhand"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY")
end

steps = Coolhand.step_template_service

result = steps.list_step_templates(step_type: "prompt_step", include_metrics: true, page: 1)
result.step_templates.each { |step| puts "#{step[:name]} (#{step[:sessions_count]} sessions)" }

lean = steps.get_step_template(result.step_templates.first[:id], include_metrics: false)
```

## `list_step_templates(search: nil, step_type: nil, include_metrics: nil, page: nil, per: nil)`

| keyword | type | notes |
|---|---|---|
| `search` | String | Case-insensitive substring match on the name. |
| `step_type` | String | `"prompt_step"` or `"tool_step"`. Anything else is a `422` from the server. |
| `include_metrics` | Boolean | Adds a `:metrics` Hash per row. Off by default; when set the server caps `per` at 25, and `pagination.per_page` reports the size applied. |
| `page` | Integer | 1-based. |
| `per` | Integer | Default 25, max 100, both enforced server-side. |

Returns a `Coolhand::StepTemplateSearchResult` (`#step_templates`, `#pagination`), newest first. The
endpoint renders a bare array; `pagination` is a `Coolhand::Pagination` read from the `X-Page`,
`X-Per-Page`, `X-Total-Count` and `X-Total-Pages` response headers, the same as `search_templates`
and `search_logs`.

## `get_step_template(id, include_metrics: nil)`

`id` is the Integer `:id` from the list (not a hashid). Anything that is not a positive Integer raises
`Coolhand::Error` before any request. Unlike the list, `:metrics` is included by default; pass
`include_metrics: false` to skip the metrics queries.

## Fields

Rows are plain Symbol-keyed Hashes, handed back as the API rendered them. Every row has `:id`,
`:name`, `:step_type`, `:status`, `:user_turn_pattern` (nil-able), `:created_at`, `:updated_at`,
`:sessions_count` (distinct sessions it appeared in), `:occurrences_count` and `:last_seen_at`
(nil-able). `:metrics` is present only when requested, or by default on `get_step_template`:

| `:metrics` field | Meaning |
|---|---|
| `:total_runs` | Runs counted; excludes scrubbed prompt-step sessions. |
| `:tool_stats` | Array of `{ name:, pct_of_runs:, avg_per_run: }`, or nil when there is nothing to show. |
| `:turn_stats` | `{ avg:, median:, high:, single_turn_pct: }` (`single_turn_pct` nil-able), or nil. |
| `:efficiency` | `{ interactive:, automated:, all:, unavailable_runs: }`, or nil for tool steps and step templates with no runs. Each cohort is nil when it has no runs. |
| `:notes` | Array of plain-sentence explanations of each data gap that applies. |

A cohort is `{ runs:, avg_turns_after:, avg_tool_calls:, avg_requests:, token_runs:, tokens_available:,
median_tokens:, p90_tokens:, tokens_per_tool_call: }`. The last three are nil, and `tokens_available`
is `false`, when no run in the cohort has token data (expected today).

## Errors

Both methods raise on failure, like the other read methods. A non-2xx response is a
`Coolhand::HttpError` whose `#status` holds the HTTP status:

| status | when |
|---|---|
| `401` | Missing, invalid or public API key. |
| `404` | `get_step_template` only: unknown id, a draft or failed step template, or another client's. |
| `422` | `list_step_templates` only: a `step_type` other than `prompt_step` / `tool_step`. |
| `504` | A query exceeded the statement timeout. Retryable: narrow with `search` or a smaller `per`. |

## Turn metrics on a log

`Coolhand.log_service.get_log(id, include_turn_metrics: true)` adds `:turn_metrics` to the log; see
[Reading Logs](log-search.md).
