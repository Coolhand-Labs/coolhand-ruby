# Reading Workloads (Search)

`Coolhand::WorkloadService#search_workloads` lists your workloads, the groups of prompt templates that
make up one task or agent, optionally with a cost and performance `metrics` rollup per workload. It
wraps `GET /api/v2/workloads`. It is read-only, and there is no per-workload endpoint.

**Auth:** requires your **private** API key. The public key is write-only on this API and is rejected
exactly like an invalid key.

**IDs:** a workload's `:id` is its **hashid**, a String. It is what the `workload_id` filter on
`search_templates` and `search_logs` expects.

**Scoping:** the client is always derived from your API key. There is deliberately no `client_id`
keyword, so passing one raises `ArgumentError`.

## `search_workloads`

```ruby
require "coolhand"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY")
end

result = Coolhand.workload_service.search_workloads(
  include_metrics: true,
  since: Time.utc(2026, 9, 1),
  until: Time.utc(2026, 10, 1),
  per: 50
)

result.workloads.each do |workload|
  puts "#{workload[:name]}: $#{workload[:metrics][:total_cost]}"
end
```

### Keywords

All optional, and named exactly like the wire parameters.

| keyword | type | notes |
|---|---|---|
| `search` | String | Case-insensitive substring match on the workload name. |
| `include_archived` | Boolean | Defaults to `false` server-side. |
| `include_system` | Boolean | `Unmatched`, `Embedding Requests` and the like. Defaults to `false` server-side. |
| `include_templates` | Boolean | Adds each workload's active templates and their routing patterns as `:templates`. |
| `include_metrics` | Boolean | Adds a `:metrics` rollup across all of the workload's templates. |
| `days_back` | Integer | Rolling metrics window ending now (server default 28, max 365). Ignored when `since` is given. |
| `since` | Time, DateTime, Date or String | Metrics window start, inclusive. Overrides `days_back`. |
| `until` | Time, DateTime, Date or String | Metrics window end, exclusive. Defaults to now. |
| `page` | Integer | 1-based. |
| `per` | Integer | Default 25, max 100, both enforced server-side. This gem only sends `per`, never its `per_page` alias. |

`false` and `0` are sent as given; only an unset (`nil`) keyword is left off the request.

### Windows: `since` and `until`

`Time`, `DateTime` and `Date` values are serialised as UTC ISO8601 (a `Date` as a date alone, which the
server reads as midnight UTC). A String is passed through untouched, so the server stays the one
validator. Anything else raises `ArgumentError` before a request is made.

```ruby
search_workloads(include_metrics: true, since: "2026-09-01")                 # date alone: midnight UTC
search_workloads(include_metrics: true, since: "2026-09-01T12:00:00+02:00")  # the + is encoded as %2B for you
```

Server-side rules, which only apply when `include_metrics` is set:

- A missing offset means UTC. `since` is inclusive and `until` is exclusive.
- With `since`, `days_back` is ignored and `metrics[:days_back]` is `nil`. With only `until`, the window
  is `days_back` long ending there.
- The prior window behind `error_rate_change` is the same length, immediately before the window.
- A malformed value, a `since` not before `until`, or a window over 365 days is a `422` with the error on
  the `since` or `until` key.

### Return value

A `Coolhand::WorkloadSearchResult`, a `Struct` with `#workloads` and `#pagination`. Rows are plain
Hashes with Symbol keys, handed back as the API rendered them so a field the server adds later reaches
you.

| field | type | notes |
|---|---|---|
| `:id` | String | Hashid. |
| `:name` | String | |
| `:description` | String or nil | |
| `:archived`, `:system`, `:merged` | Boolean | |
| `:template_count` | Integer | Active templates. |
| `:draft_template_count` | Integer | |
| `:log_count` | Integer | Every log on any of its templates, all generators, so it can exceed the sum of the templates' own `log_count`. |
| `:last_activity` | String or nil | ISO-8601 UTC. |
| `:templates` | Array | Only with `include_templates`. Each has `:id`, `:name`, `:status`, `:user_prompt_pattern`, `:system_prompt_pattern`. |
| `:metrics` | Hash | Only with `include_metrics`. See below. |

Rows are ordered by name. `pagination` is a `Coolhand::Pagination` built from the `X-Page`,
`X-Per-Page`, `X-Total-Count` and `X-Total-Pages` response headers, which this endpoint always sends,
never from the length of the array.

### `metrics`

The same object `search_templates` returns per template, computed by the same SQL as the dashboard, so
tiered pricing, cached-token discounts and reasoning tokens are applied. See
[Metrics](template-search.md#metrics) for every field.

## Errors

The read methods raise where the write methods log and return `nil`. `Coolhand::HttpError` carries
`#status` and `#body` (`{"errors": {"<field>": ["msg"]}}` on a `422`).

| status | when |
|---|---|
| `401` | No API key, an invalid key, or the public key. |
| `422` | A bad `days_back`, `since` or `until`. Only checked when `include_metrics` is set. |
| `504` | An aggregate exceeded the server's statement timeout. Retryable: narrow with `search` or a smaller `per`. |

`Coolhand::Error` covers no API key configured, a transport failure, and a body that is not a JSON array.
