# Reading Logs (Search + Get)

`Coolhand::LogService` reads logs back out of Coolhand, with the per-log `cost` the dashboard shows.
The write side, `Coolhand.logger_service`, is a different class. It wraps two read-only endpoints:

| method | endpoint |
|---|---|
| `search_logs` | `GET /api/v2/llm_request_logs` |
| `get_log` | `GET /api/v2/llm_request_logs/{id}` |

Both require your **private** API key. The public key is write-only on this API and is rejected exactly
like an invalid one.

```ruby
require "coolhand"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY")
end

logs = Coolhand.log_service

# The ten most expensive logs of the last 30 days
result = logs.search_logs(since: Time.now.utc - (30 * 86_400), order: "cost_desc", per: 10)
result.logs.each { |log| puts "#{log[:id]} #{log[:model]} $#{log[:cost]}" }

detail = logs.get_log(result.logs.first[:id])
detail[:cost_breakdown][:input_cost]
```

## `search_logs`

All keywords are optional, and named after the wire parameters (`sort` maps to `q[s]`). Two wire
parameters are not exposed: the `q[source_api_in][]` array filter, so use the single-value `source_api`
keyword, and the `per_page` alias, since this gem only sends `per`.

| keyword | type | notes |
|---|---|---|
| `template_id`, `workload_id` | String | Hashids. One that does not decode, or that belongs to another client, is a `422`. |
| `system_prompt_contains`, `user_prompt_contains` | String | Case-insensitive substring. |
| `model`, `source_api`, `source_api_result`, `source_application` | String | Exact match. `source_api_result` is `success`, `failed`, `operational` or `unmatched`. |
| `project_path` | String | Exact match against `metadata.project_path`. |
| `unmatched_only` | Boolean | Only logs with no template. |
| `days_back` | Integer | Last N days. Unset means unrestricted. Ignored when `since` or `until` is given. |
| `since`, `until` | Time, DateTime, Date or String | Bounds on `created_at`: `since` inclusive, `until` exclusive. See [Windows](workload-search.md#windows-since-and-until). |
| `min_cost` | Numeric | Only logs whose `cost` (USD) is at least this. `0` is sent. |
| `order` | String | `"cost_desc"` sorts by `cost`, highest first, replacing `sort`. Any other value is a `422` from the server. |
| `include_prompts` | Boolean | Adds `:system_prompt` and `:user_prompt`, each truncated to 500 characters. |
| `include_total` | Boolean | Asks the server for the `X-Total-*` headers. Off by default there (it skips a `COUNT(*)`). |
| `sort` | String | Ransack sort expression, sent as `q[s]`, e.g. `"created_at desc"`. |
| `page`, `per` | Integer | 1-based; `per` defaults to 25, max 100. |

`min_cost` and `order: "cost_desc"` only consider logs that can be priced (non-nil `cost`). The cost is
computed per log, so on a client with a lot of history combine them with `since` or `days_back`, or the
query can time out (`504`).

### Return value

A `Coolhand::LogSearchResult`, a `Struct` with `#logs` and `#pagination`. The response body is a bare
array, never wrapped. Rows are Symbol-keyed Hashes: `:id`, `:collector`, `:source_api`,
`:source_application`, `:metadata`, `:source_api_result`, `:model`, `:template_id`, `:template_name`,
`:input_tokens`, `:output_tokens`, `:latency_ms`, `:created_at`, `:updated_at`, `:ingest_evidence` and
`:cost`.

`:cost` is a Float in USD, or `nil` when the log has no tokens or its model has no pricing.

**Pagination without totals.** `X-Page` and `X-Per-Page` are always sent, but `X-Total-Count` and
`X-Total-Pages` only come with `include_total: true`. Without it, `pagination.total_count` and
`total_pages` are lower bounds the gem derives, not counts, and `has_next_page` is true when the page
came back full. Pass `include_total: true` when you need real totals.

## `get_log(id, section: nil, max_chars: nil, search_query: nil, include_thinking: nil)`

`id` is the log hashid. Returns the full log as a Symbol-keyed Hash: the list fields plus the prompts and
`:output`, and:

| field | type |
|---|---|
| `:cost` | Float or nil |
| `:cost_breakdown` | Hash or nil: `:total_cost`, `:input_cost`, `:output_cost`, `:cached_input_cost`, `:cache_creation_input_cost`, `:reasoning_output_cost` |

`section` (`"full"`, `"beginning"`, `"end"`), `max_chars` and `search_query` bound or search the content;
`include_thinking` adds `:thinking_response`. Truncation and search are reported back as `:truncated`,
`:total_chars`, `:search_query` and `:matches`. Only directly-collected logs are fetchable; internally
generated records are a `404`.

## Errors

The read methods raise where the write methods log and return `nil`. `Coolhand::HttpError` carries
`#status` and `#body`.

| status | when |
|---|---|
| `401` | No API key, an invalid key, or the public key. |
| `404` | `get_log` only: unknown id, another client's log, or an internally generated record. |
| `422` | Bad `template_id`, `workload_id`, `days_back`, `since`, `until`, `min_cost`, `order` or `max_chars`. |
| `504` | The search exceeded the statement timeout. Narrow the window and retry. |

`Coolhand::Error` covers no API key configured, a transport failure, a body that is not valid JSON, a
non-array list body, and a blank `id` passed to `get_log`. An unsupported `since`/`until` type raises
`ArgumentError` before any request.
