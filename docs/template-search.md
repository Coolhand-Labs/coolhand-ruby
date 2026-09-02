# Reading Templates (Search + Get)

`Coolhand::TemplateService` reads back the LLM request templates your logs are matched against.
It wraps two read-only endpoints:

| method | endpoint |
|---|---|
| `search_templates` | `GET /api/v2/llm_request_templates` |
| `get_template` | `GET /api/v2/llm_request_templates/{id}` |

Both require your **private** API key. The public key is write-only on this API and is rejected
exactly like an invalid one.

```ruby
require "coolhand"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY")
end

templates = Coolhand.template_service

result = templates.search_templates(search: "summar", status: "published")
result.templates.each { |template| puts "#{template[:name]} (#{template[:log_count]} logs)" }

detail = templates.get_template(result.templates.first[:id])
puts detail[:user_prompt_pattern]
```

## What this is not

This is **not** a port of the `search_templates` MCP tool, and the two do not agree:

- `log_count` here counts only directly-collected client logs — the same records
  `GET /api/v2/llm_request_logs?template_id=…` returns. Evals, bakeoff comparisons and synthetic
  logs are excluded, so this number is often lower than the MCP tool's.
- Templates whose workload has been archived are **returned** here, not hidden, so the list agrees
  with `get_template`, which can always fetch such a template by id. Narrow with `workload_id`
  instead.

Template *creation, update and deprecation* stay on the MCP surface. This REST surface is
read-only, and there is no version-history sub-resource.

## `search_templates(**filters)`

Search is a *parameter* on the list endpoint rather than a route of its own, so this is one method
rather than a list/search pair.

All filters are optional keyword arguments, and their names are the wire names — Ruby's convention
and this API's already agree, so there is no second spelling to translate through.

| keyword | type | notes |
|---|---|---|
| `search` | String | Case-insensitive **literal** substring match on the template name. `%` and `_` are escaped server-side and match themselves — do not escape them again. |
| `workload_id` | String | Workload hashid. One that does not decode, or that belongs to another client, is a `422` rather than an empty list. |
| `status` | String | `"draft"`, `"published"` or `"failure"`. Any other non-empty value is a `422` from the server; empty is treated as no filter. |
| `include_deprecated` | Boolean | Include templates with a non-null `deprecated_at`. Defaults to `false` server-side. |
| `include_system` | Boolean | Include the `Unmatched` / `Ignored API Calls` buckets. Defaults to `false` server-side. |
| `page` | Integer | 1-based. |
| `per` | Integer | Default 25, max 100, both enforced server-side. |

Two things it deliberately does **not** do:

- **There is no `client_id` keyword.** The client is always derived from the authenticating API key
  and cannot be supplied, so passing one raises `ArgumentError` rather than reaching the wire.
- **`status` is not checked against a client-side allowlist.** The API definition enumerates the
  values on the *query parameter*, but leaves the `status` field on the *response* an unconstrained
  string. Sending an unrecognised value gets you the server's `422`; a status the server gains
  later works without a gem release.

`per_page` is accepted on the wire as an alias for `per`. This gem only ever sends `per` — one knob
is enough.

### Return value

A `Coolhand::TemplateSearchResult` — a `Struct`, so `#templates`, `#pagination`, `#to_h` and
pattern matching all work:

```ruby
result = Coolhand.template_service.search_templates(include_system: true)

result.templates   # => [{ id: "kp9npvc8qq2q", name: "Unmatched", ... }, ...]
result.pagination  # => #<struct Coolhand::Pagination current_page=1, ...>
```

**Rows are plain Hashes with Symbol keys**, the same shape `create_feedback` and `create_log`
already return. They are handed back exactly as the API rendered them rather than being copied into
a value object, so a field the server adds later reaches you instead of being silently dropped on
the way through. That is also why there is no `system_template?` predicate: read the wire field,
`template[:system_template]`.

Rows are ordered newest first (`created_at DESC`, with a primary-key tiebreaker so paging is stable
across requests). Each carries:

| field | type | notes |
|---|---|---|
| `:id` | String | Hashid, never the integer primary key. |
| `:name` | String | Never null, but may be blank on a draft. |
| `:status` | String or nil | `draft` / `published` / `failure`. |
| `:version` | String or nil | |
| `:group` | String or nil | `chat`, `user_prompt`, `user_prompt_with_system_prompt`, `embedding`, `other`. |
| `:workload_id` | String | Workload hashid; never null. |
| `:workload_name` | String | Never null. |
| `:system_template` | Boolean | True for the `Unmatched` / `Ignored API Calls` buckets. |
| `:deprecated_at` | String or nil | ISO-8601 UTC. Non-null means the template has been superseded. |
| `:log_count` | Integer | Directly-collected client logs only — see [What this is not](#what-this-is-not). |
| `:created_at` | String | ISO-8601 UTC. |
| `:updated_at` | String | ISO-8601 UTC. |

**Prompt patterns are not in the list.** They come from `get_template` only.

`pagination` is a `Coolhand::Pagination` built from the endpoint's `X-Page`, `X-Per-Page`,
`X-Total-Count` and `X-Total-Pages` response headers — never from the size of the array, which only
ever describes the page in hand. Unlike `/llm_request_logs` there is no `include_total` opt-out
here; the headers are always sent.

| field | type |
|---|---|
| `current_page` | Integer |
| `per_page` | Integer |
| `total_count` | Integer |
| `total_pages` | Integer |
| `has_next_page` | Boolean |
| `has_prev_page` | Boolean |

### System templates and the empty default list

Every Coolhand client is created with two system buckets, `Unmatched` and `Ignored API Calls`. They
are hidden unless you pass `include_system: true`, so a client with no templates of its own gets an
empty array rather than those two rows. `Unmatched` is what you inspect when logs are misrouting:

```ruby
unmatched = Coolhand.template_service
                    .search_templates(include_system: true, search: "unmatched")
                    .templates
                    .first

puts unmatched[:log_count]
```

## `get_template(id)`

`id` is the template hashid — the `:id` field from `search_templates`.

Returns a Hash with every list field above, **plus** the full untruncated regexes the list omits:

| field | type |
|---|---|
| `:user_prompt_pattern` | String or nil |
| `:system_prompt_pattern` | String or nil |

Unlike the list, this filters on nothing but client ownership: a deprecated or system template is
reachable by id with **no opt-in flag**, because inspecting one of those is the usual reason to
fetch a template directly.

## Errors

The write methods in this gem (`create_feedback`, `create_log`, `send_llm_request_log`) log a
failure and return `nil` — instrumentation must never be the reason a host app falls over. **The
read methods are the opposite and raise**, because a caller that asked for data has to be able to
tell a `404` from a timeout from a genuinely empty result.

| raised | when |
|---|---|
| `Coolhand::HttpError` | The server answered with a non-2xx status. `#status` is the HTTP status code and `#body` the response body. |
| `Coolhand::Error` | No API key configured, a transport failure, a body that is not valid JSON, or a blank `id` passed to `get_template`. |

`Coolhand::HttpError` is a `Coolhand::Error`, so `rescue Coolhand::Error` catches both.

**Branch on `#status`, never on the message:**

```ruby
begin
  result = Coolhand.template_service.search_templates
rescue Coolhand::HttpError => e
  case e.status
  when 401 then warn "Private API key required — the public key cannot read"
  when 422 then warn "Bad filter: #{e.body}"
  when 504 then warn "Timed out aggregating log_count — narrow the query and retry"
  else raise
  end
end
```

| status | meaning |
|---|---|
| `401` | Missing, invalid, or public API key. |
| `404` | `get_template` only. Unknown id, **or** one belonging to another client — existence is not disclosed, so this is never a `403`. |
| `422` | Unrecognised `status`, or a `workload_id` that does not decode or belongs to another client. |
| `504` | See below. |

### `504` is expected, and retryable

`log_count` aggregates over `llm_request_logs`, so its cost scales with how many logs the matched
templates hold — the `Unmatched` bucket can hold every log that never matched a template. Every
query behind these responses is bounded by a 10-second statement timeout, and exceeding it returns
`504` rather than hanging. It reaches you as an `HttpError` with `status == 504`, not folded into a
generic server error, precisely so you can narrow and retry:

```ruby
templates = Coolhand.template_service

begin
  templates.search_templates(include_system: true)
rescue Coolhand::HttpError => e
  raise unless e.status == 504

  # Narrow the aggregate: one workload at a time, smaller pages.
  templates.search_templates(include_system: true, workload_id: workload_id, per: 10)
end
```

This is also why the read path waits far longer than the write path before giving up. A write
times out after 5 seconds because it runs inline in your app's own request. A read allows 60: the
server bounds each *statement* behind a response at 10 seconds, but one response runs several, so
a slow-but-working `include_system=true` call measured 7-15 seconds against a development database
while returning `200` every time. Giving up sooner would report a working endpoint as a transport
failure, and would pre-empt the `504` you are meant to see and retry.

## Verifying against a live server

The gem ships an opt-in live suite that drives both methods against a real Coolhand server with no
stubbing anywhere. Every request it makes is a read.

```bash
COOLHAND_LIVE_BASE_URL=http://127.0.0.1:3000/api \
COOLHAND_LIVE_API_KEY=<a client's private API key> \
  bundle exec rake spec:live
```

It lives in `spec/live/` and is named `*_live.rb` rather than `*_spec.rb` so RSpec's default
pattern — and therefore `bundle exec rake` and CI, which have neither a server nor a private key —
never picks it up. Nothing in it is marked pending or skipped; it simply is not matched.

Both variables are required and the suite hard-fails without them, so a missing key can never be
mistaken for a passing run. Read the key from the environment: never write it into a fixture, a
commit, or a PR body.
