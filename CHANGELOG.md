# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.1] - 2026-10-26

### Added
- **Amazon Bedrock FIPS, dual-stack and China-partition endpoints are now captured** ([#168](https://github.com/Coolhand-Labs/coolhand-ruby/pull/168)). The default intercept list held only `bedrock-runtime.*.amazonaws.com`, so calls to the FIPS hosts (`bedrock-runtime-fips.<region>.amazonaws.com`, the common case for GovCloud callers), the dual-stack IPv6 hosts (`bedrock-runtime.<region>.api.aws` and the FIPS variant) and the China partition (`bedrock-runtime.<region>.amazonaws.com.cn`) were silently not captured. A wildcard entry is an exact host match with no implicit subdomains, so each variant needs its own entry.
- Credentials in request and response bodies are redacted ([#178](https://github.com/Coolhand-Labs/coolhand-ruby/pull/178)). String values under `authorization`, `authorization_token`, `access_token`, `refresh_token`, `id_token`, `api_key`, `client_secret`, `private_key`, `secret_key` and `password` (any depth, matched by exact name) become `[REDACTED]`, as do the string values in the `headers` of an MCP tool and the ephemeral key returned by a Realtime `client_secret` response. `response_body` is now redacted too, not just `request_body`. **Migration note:** logged bodies that carry such fields now show `[REDACTED]` in Coolhand. See [Body Redaction](docs/configuration.md).
- `max_captured_body_bytes` now also caps **response** bodies ([#177](https://github.com/Coolhand-Labs/coolhand-ruby/pull/177)). A response larger than the cap (default 1 MB) is logged as a `{"_coolhand_capture_skipped": "body_too_large", ...}` marker instead of in full; your app always receives the complete response. A `body_stream` request that declares a `Content-Length` over the cap is no longer read for capture, and a non-Integer or negative cap falls back to the default instead of raising. See [Body Capture Limits](docs/configuration.md).
- `WebhookIdStore#release!(id)` and `WebhookValidator#release_claim!` ([#176](https://github.com/Coolhand-Labs/coolhand-ruby/pull/176)). A custom `webhook_id_store` may optionally implement `release!(id)`; stores that only implement `claim!` keep working unchanged.
- Batch results logged by `OpenAi::BatchResultProcessor` now carry `source_api: "openai"` and the request's `model` ([#171](https://github.com/Coolhand-Labs/coolhand-ruby/pull/171)).

- Redaction now also covers streamed and raw string bodies ([#197](https://github.com/Coolhand-Labs/coolhand-ruby/pull/197)). The JSON object or array on each `data:` line of a server-sent-event response, JSON text passed as a string, and the `request_body` / `response_body` given to `Coolhand.logger_service.forward_webhook` are parsed, redacted and re-serialized (compact output, a repeated key keeps its last value, numbers go to double precision). `[DONE]`, event and comment lines and plain text are left as received; a payload that cannot be redacted is replaced by a `{"_coolhand_capture_skipped": "redaction_failed"}` marker. **Migration note:** logged SSE and webhook bodies that carry credential-named fields now show `[REDACTED]`. See [Body Redaction](docs/configuration.md).
- Credentials in URL-valued body fields and more credential keys are redacted ([#193](https://github.com/Coolhand-Labs/coolhand-ruby/pull/193)). String values under `url`, `server_url`, `image_url`, `file_url` and `endpoint` that are a single absolute URL go through the URL sanitizer, and string values under `x-api-key`, `secret`, `aws_secret_access_key`, `session_token` and `bearer_token` are redacted. A secret in a URL path cannot be detected and is sent as is.
- Batch item bodies and chunked request bodies respect `max_captured_body_bytes` ([#198](https://github.com/Coolhand-Labs/coolhand-ruby/pull/198)). The OpenAI and Vertex batch processors cap each item's request and response body with the `body_too_large` marker and read OpenAI result files line by line, skipping malformed lines instead of dropping the file. A chunked `body_stream` request is no longer read ahead of the send: a read-only tap copies the bytes Net::HTTP reads, and the log entry is built after the send. New markers: `body_stream_incomplete`, `unsupported_body_stream`, `nesting_too_deep`, `unserializable_body`.
### Changed
- **Breaking:** `Coolhand.public_content_service` is now `Coolhand.help_center_service`, and `Coolhand::PublicContentService` is now `Coolhand::HelpCenterService` ([#167](https://github.com/Coolhand-Labs/coolhand-ruby/pull/167)). The old names are removed with no deprecated alias. **Migration note:** anyone calling `public_content_service` on v0.10.0 must switch to `help_center_service`; method signatures (`search_help_articles`, `get_help_article`, `list_help_categories`) and the requests sent are unchanged.
- OpenAI webhook ids are remembered for twice `webhook_replay_tolerance_seconds` ([#176](https://github.com/Coolhand-Labs/coolhand-ruby/pull/176)), and the claim is released when your `process_event` raises, so OpenAI's retry of the same `webhook-id` is processed instead of being rejected as a replay. The response is still 401 on failure. **Migration note:** a custom `webhook_id_store` now receives `2 * webhook_replay_tolerance_seconds` as `ttl_seconds`.
- Rate-limit headers (`x-ratelimit-remaining-tokens`, `anthropic-ratelimit-input-tokens-reset`, ...) are no longer redacted in captured logs ([#174](https://github.com/Coolhand-Labs/coolhand-ruby/pull/174)). The allow-list is closed-vocabulary: `x-ratelimit-api-key` and similar are still redacted.
- Relative batch input URLs (`/v1/chat/completions`) are logged as `https://api.openai.com/v1/chat/completions` ([#171](https://github.com/Coolhand-Labs/coolhand-ruby/pull/171)).
- Docs: `docs/anthropic.md` now describes the unified `NetHttpInterceptor` instead of the removed `FaradayInterceptor` ([#169](https://github.com/Coolhand-Labs/coolhand-ruby/pull/169)). CI: `ruby/setup-ruby` bumped to 1.335.0 for the Ruby 3.3.13 / 3.4.12 / 4.0.9 regexp security fixes ([#175](https://github.com/Coolhand-Labs/coolhand-ruby/pull/175)). Test coverage gaps closed (webhook secret handling, sanitizer negatives, batch wire payloads) ([#172](https://github.com/Coolhand-Labs/coolhand-ruby/pull/172)).

- Request paths are normalized before `exclude_api_patterns` and path-anchored `intercept_addresses` matching ([#195](https://github.com/Coolhand-Labs/coolhand-ruby/pull/195)): repeated `/` are collapsed, `.` and `..` segments resolved and unreserved percent-escapes decoded, so `/openai//files` or `/openai/%66iles` can no longer slip past an exclusion. An exclusion matches if the raw or the normalized path matches. Matching stays case-sensitive. The URL that is sent and logged is unchanged. **Migration note:** a custom anchor or pattern containing `//`, `..` or an unreserved escape no longer matches the normalized form.
- URL fragments are dropped by the URL sanitizer ([#191](https://github.com/Coolhand-Labs/coolhand-ruby/pull/191)), so `#access_token=...` no longer reaches Coolhand. **Migration note:** logged and forwarded URLs no longer include a `#fragment`.
### Security
- **`OpenAi::WebhookValidator` no longer accepts unsigned webhooks in `development` and `test` when a secret is set** ([#170](https://github.com/Coolhand-Labs/coolhand-ruby/pull/170)). Previously a request missing the `webhook-signature` / `webhook-timestamp` / `webhook-id` headers passed in those environments, so an app running with `RAILS_ENV=development` on a reachable host accepted forged `batch.completed` events. **Migration note:** unsigned test payloads posted to a local app that has a secret configured now get a 401. Sign the payload (snippet in [docs/openai.md](docs/openai.md#local-development-and-testing)), leave the secret unset in development, or replay a real delivery. With no secret configured, development and test still skip verification with a warning.
- `OpenAi::BatchResultProcessor` validates the batch id and the input/output file ids before using them in OpenAI API calls made with your `OPENAI_API_KEY` ([#171](https://github.com/Coolhand-Labs/coolhand-ruby/pull/171)), and skips a batch with missing or invalid `in_progress_at` / `completed_at` instead of logging epoch-0 timestamps. **Migration note:** events whose ids don't match `batch_...` / `file-...` are now ignored with an error in `Rails.logger`.
- `LoggerService#forward_webhook` no longer forwards the whole Rack env ([#173](https://github.com/Coolhand-Labs/coolhand-ruby/pull/173)). `headers: request.headers` iterates every Rack env entry, so session and request data (`rack.session`, `action_dispatch.*`) and CGI variables such as `QUERY_STRING` were shipped to Coolhand. Dotted keys and CGI/server variables are now skipped, while `HTTP_*`, `CONTENT_TYPE` and `CONTENT_LENGTH` are kept, and a caller-supplied `url:` is sanitized. **Migration note:** forwarded headers no longer include `remote-addr`, `request-method`, `query-string`, `path-info` and similar.
- URL and header redaction gaps closed ([#174](https://github.com/Coolhand-Labs/coolhand-ruby/pull/174)): the query params `code`, `sas`, `pwd` and `passwd` (exact name, case-insensitive), `;name=value` matrix params in paths and query values, and bare query segments with no `=` are redacted, and URL-form string values under `data_sources` (e.g. an `endpoint` with embedded credentials) are sanitized. Percent-escaped invalid UTF-8 in a param name no longer raises.
- A host streaming block that raises no longer leaks its message into the log ([#179](https://github.com/Coolhand-Labs/coolhand-ruby/pull/179)): `response_body.error.message` is now the fixed placeholder `"[redacted: raised in host streaming block]"` (transport errors keep their message). A non-intercepted request made inside an outer streaming block no longer has its chunks appended to the outer request's logged `response_body`.
- Release red-team hardening. The URL sanitizer now also redacts the query params `jwt`, `bearer`, `session`, `cookie`, `passphrase`, `ticket`, `assertion` (by substring) and `pass`, `sid`, `otp` (exact name). A JSON body nested deeper than 100 levels is logged as a `nesting_too_deep` marker instead of the raw string, which skipped body redaction. `BaseInterceptor.sanitize_headers` returns `{}` for an input shape it can't enumerate instead of logging its `to_s`. A failure while recording a response (or a streamed chunk) is now logged and swallowed instead of raising into the host app's already-successful request. **Migration note:** logged URLs with such params now show `[REDACTED]`.
- `OpenAi::WebhookValidator` rejects a nil payload in every `Rails.env` when a secret is set ([#192](https://github.com/Coolhand-Labs/coolhand-ruby/pull/192)), matching the missing-header rule above. An empty-string body still goes to the signature check. **Migration note:** a nil body posted to a local app that has a secret configured now gets a 401.
- `LoggerService#forward_webhook` forwards only `HTTP_*`, `CONTENT_TYPE` and `CONTENT_LENGTH` when the input looks like a whole Rack env ([#196](https://github.com/Coolhand-Labs/coolhand-ruby/pull/196)) (it has a `REQUEST_METHOD` key, a lowercase dotted key like `rack.input`, or only `UPPER_CASE` keys), so process env vars such as `DATABASE_URL` or `REDIS_URL` on CGI-style servers are no longer shipped. **Migration note:** a plain hash whose keys are all uppercase (`{"ETAG" => ...}`) is treated as an env and its non-`HTTP_*` entries are dropped; `HTTP_PROXY` is always dropped.
- `WebhookInterceptor#intercept_batch_request`, `#webhook_secret` and `#process_event` are now private and excluded from the controller's `action_methods` ([#194](https://github.com/Coolhand-Labs/coolhand-ruby/pull/194)), so they cannot be routed to as actions. **Migration note:** calling them from outside the controller raises `NoMethodError`, and the three names are reserved; define `webhook_secret` under `private` in your controller (see [docs/openai.md](docs/openai.md)).

## [0.10.0] - 2026-10-21

### Added
- **Read the Coolhand help center** ([#164](https://github.com/Coolhand-Labs/coolhand-ruby/pull/164)) — `Coolhand.public_content_service` wraps the read-only help center endpoints: `search_help_articles(query:, category:, page:, per_page:)` returns a `Coolhand::HelpArticleSearchResult` (`articles`, `pagination`), `get_help_article(slug)` returns one article with its markdown `body` and `toc`, and `list_help_categories` lists the sections. Unlike every other read service it needs **no API key**: with none configured no `X-API-Key` header is sent (anonymous callers are limited to 30 requests per minute per IP), and a configured `config.api_key` is sent and lifts the limit. Like the other read methods, these raise `Coolhand::Error` / `Coolhand::HttpError` rather than logging and returning `nil`. See [Reading the Help Center](docs/help-center.md).

### Security
- `LoggerService#forward_webhook` now redacts credentials (userinfo and sensitive query parameters such as `token=`) in a caller-supplied `url:` before logging it, the same way intercepted request URLs are. **Migration note:** if you pass a `url:` containing such values, they now appear as `[REDACTED]` in Coolhand.

## [0.9.0] - 2026-10-18

### Added
- **Declare the workload and template of captured LLM calls** ([#153](https://github.com/Coolhand-Labs/coolhand-ruby/pull/153)) — `Coolhand.with_context(reporter:, workload:, template:) { ... }` stamps every LLM call captured inside the block with the workload and template it belongs to, sent as `llm_request_log.declared`. The context is snapshotted on the calling thread, so it survives `async_logging`. Nested blocks override per field (innermost wins). `Coolhand::Declarable` (`coolhand_workload`, `coolhand_declare`, `coolhand_declare_all`) declares it once on a class, inherited by subclasses, and opt-in `config.auto_declare = [:active_job, :controller]` does the same for Rails jobs and controller actions (the gem still has no Rails dependency). `Coolhand.workload_service.upsert` and `Coolhand.template_service.upsert` create or update records by key with your **private** API key and raise `Coolhand::HttpError` on failure, and `warnings` returned with a logged request (e.g. the public-key cap) are now logged. Keys longer than 255 characters, with surrounding whitespace or a leading, trailing or doubled `/`, and a template `key` with no workload raise `ArgumentError` up front, because the server would reject and drop the whole log. Older servers ignore `declared`. See [Declared Workloads](docs/declared_workloads.md).
- `bin/live-examples` (also `bundle exec rake examples:live`) runs every `examples/*.rb` against real provider keys and prints one `PASS` / `SKIP` / `FAIL` line per script ([#155](https://github.com/Coolhand-Labs/coolhand-ruby/pull/155)). Development tooling only: `bin/` and `examples/` are not packaged in the gem. See [Examples](examples/README.md).

### Changed
- The `🔗 Net::HTTP interceptor patched` log line is no longer printed when the interceptor is installed ([#154](https://github.com/Coolhand-Labs/coolhand-ruby/pull/154)). **Migration note:** anything that matched on that line in log output should stop doing so; use `Coolhand::NetHttpInterceptor.patched?` instead.
- Internal de-duplication with no behavior change ([#156](https://github.com/Coolhand-Labs/coolhand-ruby/pull/156)): list reads share `ReadQuery#fetch_list`, `LoggerService` shares one webhook-rejection path, `OpenAi::WebhookValidator` shares one enforce-or-allow path (same error messages and same strict/lenient behavior by `Rails.env`), and `Coolhand.with_capture` / `without_capture` share one override helper. `contract/` (declared, intentional duplication) is excluded from the gem package.
- CI: added the `exhale` duplication and complexity gate ([#156](https://github.com/Coolhand-Labs/coolhand-ruby/pull/156)), and bumped `ruby/setup-ruby` to 1.329.0 ([#150](https://github.com/Coolhand-Labs/coolhand-ruby/pull/150)) and `actions/upload-artifact` to 7.0.2 ([#151](https://github.com/Coolhand-Labs/coolhand-ruby/pull/151)).

### Fixed
- `OpenAi::WebhookValidator` now accepts a `webhook-signature` header carrying several space-separated signatures (`v1,sigA v1,sigB`) and passes if any `v1,` entry matches ([#161](https://github.com/Coolhand-Labs/coolhand-ruby/pull/161)). Previously the whole remainder after `v1,` was compared as one value, so a legitimate webhook sent during secret rotation was rejected with a 401. Every candidate is compared in constant time, non-`v1` entries are ignored, a header that is not valid UTF-8 is rejected rather than raising, and the timestamp and replay-id checks still run only after a match. Single-signature headers behave as before. See [OpenAI Batch Webhook Handler](docs/openai.md#signature-header-and-secret-rotation).

### Security
- Warnings returned in a Coolhand log response are now sanitized before they are printed ([#162](https://github.com/Coolhand-Labs/coolhand-ruby/pull/162)): entries are coerced with `to_s`, invalid UTF-8 is scrubbed, control characters and line separators become a space, invisible Unicode format characters are removed, entries over 500 characters are truncated, and at most 5 are printed per response. Well-formed warnings print as before.

### Documentation
- `docs/declared_workloads.md` and the README now state that `Coolhand.with_context`, `with_capture` and `without_capture` are fiber-local, so work started in a new Fiber or Async task inside the block is not covered, and show opening the block inside the Fiber instead ([#160](https://github.com/Coolhand-Labs/coolhand-ruby/pull/160)).

## [0.8.0] - 2026-10-09

### Added
- **Read workloads and logs, with cost and performance metrics** ([#138](https://github.com/Coolhand-Labs/coolhand-ruby/pull/138)) — `Coolhand.workload_service.search_workloads` lists workloads (`GET /api/v2/workloads`) and `Coolhand.log_service` reads logs back out: `search_logs` (filters including `since`, `until`, `min_cost`, `order`, `project_path`, `source_application`, `include_total`, `sort`) and `get_log`, which returns `cost` and `cost_breakdown`. `search_templates` and `get_template` gain `include_metrics`, `days_back`, `since` and `until`. `since:`/`until:` accept a `Time`, `DateTime`, `Date` or ISO8601 String; anything else raises `ArgumentError` before a request is made. These need your **private** API key and raise `Coolhand::Error` (`Coolhand::HttpError` for non-2xx responses) rather than logging and returning `nil`. **Deploy note:** requires the matching Coolhand server release (Coolhand-Labs/coolhand#1753). See [Reading Workloads](docs/workload-search.md) and [Reading Logs](docs/log-search.md).
- **Link feedback to an optimization** ([#133](https://github.com/Coolhand-Labs/coolhand-ruby/pull/133)) — `Coolhand.optimization_feedback_link_service` provides `link_feedback`, `bulk_link_feedback` (sent in batches of 100, results summed) and `unlink_feedback` for `/api/v2/optimizations/:id/feedback_links`. Private API key required; failures raise `Coolhand::Error` / `Coolhand::HttpError`. See [Linking Feedback](docs/feedback-links.md).
- **Logs are sent from a background queue by default** ([#148](https://github.com/Coolhand-Labs/coolhand-ruby/pull/148)) — the Coolhand POST no longer runs inline in the intercepted LLM call, so a slow or unreachable Coolhand backend can no longer add up to about 10s to each call. `Coolhand::LogQueue` holds up to 1,000 jobs per lane and drops the oldest when full, restarts itself in forked processes, and flushes at exit (waiting up to 5s). OpenAI and Vertex batch results are processed as one background job per batch, on their own lane so a long batch cannot delay or evict per-request logs. New `config.async_logging` (default `true`) and `Coolhand.flush(timeout: 5)`; `examples/benchmark_async_logging.rb` is a pass/fail benchmark. See [Asynchronous Logging](docs/configuration.md#asynchronous-logging). **Migration note:** anything that relied on the log POST finishing before the intercepted call returned (tests asserting on a stubbed `ApiService` inline, scripts that end with `exit!`, a process killed by `kill -9` or the OOM killer, which loses queued logs) should set `config.async_logging = false` or call `Coolhand.flush`. `debug_mode` always runs inline.

### Changed
- Repo guidance moved from `CLAUDE.md` to `AGENTS.md` ([#130](https://github.com/Coolhand-Labs/coolhand-ruby/pull/130)), and the agent-harness review handshake in `AGENTS.harness.md` was rewritten ([#134](https://github.com/Coolhand-Labs/coolhand-ruby/pull/134)). Neither ships in the gem, and `AGENTS.md` is excluded from the gem package in place of `CLAUDE.md`.
- CI now uses `ruby/setup-ruby` 1.327.0 ([#135](https://github.com/Coolhand-Labs/coolhand-ruby/pull/135)).
- Shared read-URL building moved into `Coolhand::ReadQuery`, and POST/DELETE helpers that raise on failure into `Coolhand::WriteRequests`; `TemplateService` now uses `ReadQuery`. Internal refactor with no behavior change to `search_templates`/`get_template` beyond the new options.
- `Coolhand::NetHttpInterceptor` no longer includes `BaseInterceptor` ([#148](https://github.com/Coolhand-Labs/coolhand-ruby/pull/148)); its helpers moved to `Coolhand::NetHttpInterceptor::Helpers`, so `Net::HTTP` gains only `#request` instead of about 15 generically named private methods (`intercept?`, `parse_json`, `sanitize_url`, ...). **Migration note:** internal API, but if you called those helpers on a `Net::HTTP` instance, use `Coolhand::NetHttpInterceptor::Helpers` or `Coolhand::BaseInterceptor`.

### Fixed
- Disabling the Net::HTTP interceptor logged a stale "Faraday monitoring disabled" message ([#148](https://github.com/Coolhand-Labs/coolhand-ruby/pull/148)); it now says "Net::HTTP interceptor unpatched (capture stopped)".

### Security
- **Release-time hardening from a whole-package security review** ([#148](https://github.com/Coolhand-Labs/coolhand-ruby/pull/148), plus fixes made on the release branch):
  - Requests forwarded by the OpenAI batch webhook handler now go through the same request-body redaction as live interception, so Azure OpenAI "On Your Data" datastore credentials in a batch request body are replaced with `[REDACTED]` before being sent to Coolhand.
  - The OpenAI batch handler now matches requests to results with a one-pass index instead of a scan per result, so a large batch no longer takes quadratic time. When a `custom_id` is duplicated the first request still wins, as before.

## [0.7.0] - 2026-09-20

### Added
- **Seven more providers are monitored out of the box** ([#117](https://github.com/Coolhand-Labs/coolhand-ruby/pull/117)) — DeepSeek (`api.deepseek.com`), Mistral (`api.mistral.ai`), Perplexity (`api.perplexity.ai`) and xAI (`api.x.ai`) are captured host-wide. Cohere is captured only on its chat and embed endpoints (`/v2/chat`, `/v1/embed`, `/v2/embed`, on `api.cohere.com` and `api.cohere.ai`), TypeSafe Jev only on `api.typesafe.ai/v1/systemone`, and Ollama only on port 11434 for `/api/chat`, `/api/generate`, `/api/embed` and `/api/embeddings` (`localhost`, `127.0.0.1`, or a bare single-label host such as a Docker Compose service). No configuration required. **Migration note:** if your app already calls any of these, those calls will now start being logged to Coolhand after upgrading. To opt out, override `config.intercept_addresses` with your own list.
- **Azure inference endpoints are monitored out of the box** ([#115](https://github.com/Coolhand-Labs/coolhand-ruby/pull/115)) — Azure OpenAI dedicated hosts (`openai.azure.com`/`.us`/`.cn`), Azure AI Services / Foundry multi-service hosts (`cognitiveservices.azure.*`, `services.ai.azure.*`, captured only on their `/openai/` and `/models/` paths), serverless/MaaS hosts (`inference.ai.azure.com`, `models.ai.azure.com`) and Azure ML managed online endpoints (`inference.ml.azure.com`/`.us`). The Azure ML entries are deliberately not path-anchored, because every managed online endpoint scores at `/score`, so non-LLM deployments there will also be captured. Remove those two entries from `intercept_addresses` if that over-captures for you. Default `exclude_api_patterns` now also skips Azure OpenAI control-plane paths (`/openai/files`, `/batches`, `/fine_tuning`, `/models`, and their `/openai/v1/` spellings). **Migration note:** anyone who set `exclude_api_patterns` explicitly keeps their own list and will not get the new Azure exclusions.
- **`intercept_addresses` entries can pin a port and/or a path prefix** ([#117](https://github.com/Coolhand-Labs/coolhand-ruby/pull/117), [#115](https://github.com/Coolhand-Labs/coolhand-ruby/pull/115)) — `host:port`, `host/path` and `host:port/path` are all accepted. A request must match every part, and the path matches on a segment boundary (`host/openai` matches `/openai` and `/openai/x`, not `/openaiz`). Plain-host entries behave exactly as before. See [Configuration](docs/configuration.md#custom-intercept-addresses).

### Changed
- Ruby 4.0 was added to the CI matrix ([#113](https://github.com/Coolhand-Labs/coolhand-ruby/pull/113)) and then removed again before release: its job could not `bundle install` against the locked dependencies (`BUNDLED WITH 2.3.6`, the conditional `pry-byebug`/`debug` Gemfile entry and `unicode-emoji 4.1.0`). CI covers Ruby 3.1–3.4 until the lock can support 4.0.

### Fixed
- `examples/anthropic_example.rb` could not run against the pinned `anthropic` 0.4.x gem: it relied on the client reading `ANTHROPIC_API_KEY` from the environment and on object-style response access, and it targeted a retired model. It now passes `access_token:` explicitly, reads the response as a Hash, and uses `claude-haiku-4-5-20251001`. Found by running it against a live key during release validation.

### Security
- **Azure OpenAI "On Your Data" datastore credentials are now redacted from captured request bodies** ([#115](https://github.com/Coolhand-Labs/coolhand-ruby/pull/115)) — a request's `data_sources`/`dataSources` entries can carry live credentials (Azure AI Search API keys, Cosmos/Mongo connection strings, Elasticsearch encoded keys) that header and URL sanitization never looked at. `BaseInterceptor.sanitize_body` now replaces any value under those entries whose key name contains `key`, `token`, `secret`, `password`, `credential`, `connectionstring` or `signature` (separators and case ignored) with `[REDACTED]` before the log is forwarded. Message content and tool definitions outside `data_sources` are untouched.
- **Release-time hardening from a whole-package security review** ([#148](https://github.com/Coolhand-Labs/coolhand-ruby/pull/148), plus fixes made on the release branch):
  - `Coolhand.log` no longer raises when stdout is unwritable. Previously a failing `puts` inside the interceptor's `ensure` block could replace the host application's own LLM response with an `IOError`.
  - A bad `intercept_addresses`/`exclude_api_patterns` value (e.g. a String or Symbol instead of an array of Strings) now degrades to "don't capture" instead of raising into every intercepted request.
  - `BaseInterceptor.sanitize_url` now fails closed on an unparseable URL, dropping userinfo, query and fragment rather than returning the raw URL with credentials intact.
  - Header redaction now also matches names containing `auth`, `passw`, `credential`, `bearer`, `jwt` or `session` (e.g. `X-Auth`, `X-Session-Id`, `X-Jwt`). **Migration note:** headers such as `x-session-id` now appear as `[REDACTED]` in Coolhand.
  - `sanitize_body` matches the `data_sources` key case- and separator-insensitively, and also redacts `pwd`, `passw*`, `bearer` and `jwt` credential keys.
  - Hosts with a trailing dot (`api.openai.com.`) are now matched like their dotless form.
  - `OpenAi::WebhookValidator` rejects a bare `whsec_` secret, which decodes to an empty HMAC key and would make signatures forgeable.

### Documentation
- Clarified that Google's "Gemini Enterprise Agent Platform" is the new marketing name for Vertex AI and does not change `aiplatform.googleapis.com` or `Coolhand::Vertex` ([#118](https://github.com/Coolhand-Labs/coolhand-ruby/pull/118)).

## [0.6.0] - 2026-09-12

### Added
- **`Coolhand::TemplateService`, reached via `Coolhand.template_service`** — reads LLM request templates back out of Coolhand (`GET /api/v2/llm_request_templates`, `GET /api/v2/llm_request_templates/{id}`). `search_templates` filters and pages, returning a `Coolhand::TemplateSearchResult` of `templates` and `pagination`; `get_template` adds the `user_prompt_pattern`/`system_prompt_pattern` regexes the list omits. Both require the **private** API key — the public key is write-only on this API. Needs a server carrying these endpoints; a self-hosted one that predates them answers `404`. See [docs/template-search.md](docs/template-search.md) (#105).
- **`Coolhand::HttpError`** — raised by the read methods on a non-2xx response, carrying `#status` and `#body` so a caller can branch on `401` vs `404` vs `504` without matching message text. It subclasses `Coolhand::Error`, so `rescue Coolhand::Error` still catches everything this gem raises.
- **OpenCode added to default intercept addresses** — `opencode.ai` (OpenCode Zen's OpenAI-compatible gateway) is now monitored out of the box with no configuration required. Since matching is now host-based (see Security below), this also covers requests to `api.opencode.ai` without needing a separate entry, so misrouted requests show up in logs instead of vanishing (#97).
- **`examples/`** — runnable scripts (`openai_example.rb`, `anthropic_example.rb`, `elevenlabs_example.rb`) that make a real provider call through Coolhand, useful as a live smoke test. Excluded from the packaged gem. See [Examples](examples/README.md) (#109).

### Changed
- **`config.intercept_addresses = []` (or `nil`) now logs a warning instead of silently doing nothing.** `intercept_addresses` is a required allow-list — an empty list would mean "capture nothing" — so `[]` has always been ignored and the previous value kept, unlike the deny-list `exclude_api_patterns`, which genuinely supports `= []` to disable exclusion. That asymmetry meant a user modeling `intercept_addresses` on its sibling setting got no error and no signal that anything happened. Behavior is unchanged; it's just no longer silent. Documented next to both settings in `docs/configuration.md` and the README (#89).
- **The read methods raise where the write methods return `nil`.** `send_llm_request_log`, `create_log` and `create_feedback` still log a failure and return `nil`; the new read methods raise `Coolhand::HttpError`, because a caller that asked for data has to be able to tell a `404` from a timeout from a genuinely empty result. Reads also allow 60 seconds where writes allow 5.
- **`search_templates` is not a port of the `search_templates` MCP tool and does not agree with its numbers.** `log_count` here counts only directly-collected client logs, so evals, bakeoff comparisons and synthetic logs are excluded; templates whose workload has been archived are returned rather than hidden.
- `Coolhand::Error` moved from `lib/coolhand.rb` into a new `lib/coolhand/errors.rb`, alongside `Coolhand::HttpError`, and is now required first. The constant, its superclass and its behaviour are unchanged.
- The GET half of `Coolhand::ApiService` now lives in a `Coolhand::ReadRequests` mixin (`lib/coolhand/read_requests.rb`), keeping the class inside this repo's 200-line budget, with `format_error_body` and `apply_headers` extracted from the POST path and shared by both halves. The one write-path behaviour change: a failed response body over 2000 characters is now truncated in the log line instead of printed in full.

### Security
- **`NetHttpInterceptor`'s patched/unpatched state is no longer a plain boolean shared across threads.** `Coolhand.capture` snapshotted `NetHttpInterceptor.patched?` before yielding and used that snapshot at the end of a potentially long-running block (an in-flight HTTP request) to decide whether to unpatch. Two threads concurrently entering `Coolhand.capture` before the interceptor was already permanently patched could both observe `patched? == false`, and whichever thread's block finished first would call `unpatch!`, silently disabling interception for the other thread's still in-flight request. `patch!`/`unpatch!` are now a mutex-guarded reference count, so overlapping/nested callers compose correctly and the interceptor only actually unpatches once every outstanding caller has released it (#90). One behavior change: `patch!` is no longer idempotent on its own — every call now needs a matching `unpatch!` to release it, so an app that calls `Coolhand.configure` more than once (e.g. a reloader re-running an initializer) holds an extra, permanent reference each time rather than no-op'ing. This is harmless (interception simply stays on) but is a change from the prior behavior.
- **Captured request bodies are now capped in size and skipped entirely for non-JSON content types.** `Coolhand::NetHttpInterceptor#capture_request_body` previously read the entirety of `req.body_stream` (or `req.body`/the `body` param) into memory with no limit and forwarded it in full as `request_body` — since `intercept?` matches configured hosts on any path, a large upload to an endpoint like `/v1/files`, `/v1/audio/transcriptions`, or `/v1/batches` was held in memory and shipped to Coolhand's API in its entirety. A binary/multipart upload (audio, a batch JSONL file, a fine-tune corpus) is now skipped before it's ever read into memory for capture, and any body over the new `config.max_captured_body_bytes` (default 1 MB) is replaced with a placeholder instead of the full content. The real request to the LLM provider is unaffected — only what gets captured/logged changes (#88).
- **`Coolhand::OpenAi::WebhookValidator#should_enforce_strict_validation?` no longer fails open on unrecognized `Rails.env` names.** It previously blocklisted `"production"`/`"staging"` exactly, so any other spelling — `"prod"`, `"production-eu"`, a Heroku/Render `"review"` app env, or an unset `Rails.env` — fell into the permissive fallback path, where a missing/misconfigured webhook secret let an unsigned request pass as valid. It now uses a fail-safe allowlist of `"development"`/`"test"` — every other value, including `nil`, enforces strict validation (#84).
- **The full captured request/webhook body is no longer printed to stdout by default.** `Coolhand::ApiService#log_request_info` (reached via `LoggerService#log_to_api`/`#forward_webhook`) previously dumped the entire captured payload — including raw webhook bodies like voice-call transcripts — to stdout whenever `silent` was `false` (the default). In a containerized deploy, stdout typically flows straight into a log aggregator with a different retention/access model than Coolhand itself. It now logs only an identifier and a byte count by default; the full payload is still printed when `debug_mode` is explicitly enabled (#87).
- **A previously-valid OpenAI webhook request can no longer be replayed indefinitely.** `Coolhand::OpenAi::WebhookValidator#verify_signature` included `webhook-timestamp` and `webhook-id` in the signed payload, but never checked the timestamp for freshness or tracked the id for idempotency — a signature computed over a `webhook-timestamp` from the past (e.g. captured from a log aggregator, an APM trace, or a proxy log) still validated as `true`, and each replay re-triggered `Coolhand::OpenAi::BatchResultProcessor`, causing redundant OpenAI file downloads and duplicate request logs. It now rejects requests whose `webhook-timestamp` is more than `Coolhand.configuration.webhook_replay_tolerance_seconds` (default 300, matching the Standard Webhooks tolerance) away from the current time, and atomically claims `webhook-id` via a new `Coolhand.configuration.webhook_id_store` (default: an in-memory, per-process, TTL-bounded store — swappable for multi-process deployments), rejecting a request whose id was already claimed within the window. A missing `webhook-id` header (previously only the signature/timestamp headers were required) is now also treated as a missing-headers failure, rather than falling through as `nil` and letting two distinct requests both dedupe against the same `nil` key (#86).
- **`intercept_addresses` and `exclude_api_patterns` no longer match against the raw URL string.** `Coolhand::NetHttpInterceptor#intercept?`/`#excluded_by_pattern?` previously did `url.include?(entry)` against the whole URL, so a configured entry like `"api.openai.com"` could be triggered by an attacker-controlled URL that merely *mentions* it — `https://evil.com/redirect?to=api.openai.com` (wrong destination) or `https://api.openai.com.attacker.net/...` (suffix confusion) both wrongly matched, while `https://API.OPENAI.COM/...` wrongly didn't (case-sensitive). Matching is now done against the parsed `uri.host`, exact or dot-boundary suffix, case-insensitively — so a request can only be captured because it's actually going to a configured host. `exclude_api_patterns` now matches only `uri.path`, so a pattern like `/batchPredictionJobs/` can no longer be tripped by an unrelated request that merely has it in a query string.
- **Bare, hostless entries (`:generateContent`, `:streamGenerateContent`) have moved out of `intercept_addresses` into a new `intercept_path_patterns` setting.** These colon-suffixed path tokens (Google's API Discovery convention) had no host component, so under the old substring matching *any* URL whose path happened to contain them — e.g. `https://attacker.tld/:generateContent` — was wrongly captured. They're now matched only against the path of requests whose host is already `googleapis.com` or a subdomain of it, and can never match on their own — and only take effect at all if `intercept_addresses` still includes a `googleapis.com` host, so overriding `intercept_addresses` to exclude Google entirely also disables `intercept_path_patterns`.
- **The default AWS Bedrock entry (`bedrock-runtime`) is now the precise host pattern `bedrock-runtime.*.amazonaws.com`** instead of a bare substring, using new minimal wildcard support in host matching (a single `*` matches exactly one host label). Previously it matched anywhere `"bedrock-runtime"` appeared in a URL, not just the real Bedrock host.
- **`LoggerService#forward_webhook`'s `response_headers:` option is now redacted like every other header path in the gem.** It was passed straight through to Coolhand unredacted — unlike the sibling `headers:` option — so a caller forwarding a provider webhook alongside its own upstream response (e.g. `forward_webhook(..., response_headers: upstream_response.to_hash)`) shipped that response's `Authorization`/`Set-Cookie`/signature headers to Coolhand in plaintext.
- **`Coolhand::BaseInterceptor.sanitize_url` now redacts credentials embedded in a URL's userinfo component** (`https://user:pass@host/...`), not just sensitive query parameters. Previously a URL with no query string returned immediately, before userinfo was ever inspected.
- **`Coolhand::OpenAi::BatchResultProcessor`'s request-log URL is now run through the shared `sanitize_url`**, instead of being forwarded as-is — this path had its own hand-written logging call that predated (and didn't pick up) the shared header/URL sanitization used everywhere else in the gem.

### Dependencies
- Bumped `json` to 2.21.2, flagged by `bundler-audit` (GHSA-9hj4-r449-hfvc: `JSON::ResumableParser#partial_value` dereferences a freed input buffer on truncated duplicate-key streams). `json` is a transitive dependency (via `rubocop`/`faraday`), not something this gem or its consumers pin directly.

## [0.5.1] - 2026-08-02

### Added
- **`Coolhand::Vertex::BatchResultProcessor.new` accepts an optional `model:` keyword** (falls back to a `"model"` key in `batch_info` when omitted) to populate the `model` field on batch-result logs — included only when one of those is available and non-blank, and omitted from the payload entirely otherwise (#76).
- **`Coolhand::BaseInterceptor.send_complete_request_log` accepts optional `source_api:`/`model:` keywords**, for synthetic/batch log types (like the Vertex processor above) that aren't backed by a real intercepted HTTP request (#76).

### Changed
- **Vertex batch results with a missing or malformed job resource name or unparseable `startTime`/`endTime` are no longer logged at all.** Previously the processor still sent a request log using whatever was in `batch_info["name"]` (even if blank), just with a broken URL. It now validates these fields and skips the log entirely — with a `Rails.logger.error` explaining why — rather than sending something unusable (#76).
- **A batch whose `endTime` precedes its `startTime` (e.g. clock skew) is still logged**, with `duration_ms` clamped to `0` and a warning logged, rather than dropped — unlike the missing/malformed cases above, the request/response content itself is still valid here (#76).
- **A Vertex batch result item that isn't a `Hash` with a `"request"` and/or `"response"` key is now rejected and logged as an error**, instead of being sent as a log with `nil` request/response bodies (#76).
- **The published gem no longer packages `.claude/`, `.idea/`, or `CLAUDE.md`** — these are repo/agent tooling, not part of the library.

### Security
- **A webhook processing error no longer leaves the request authenticated by default.** `Coolhand::WebhookInterceptor#intercept_batch_request` previously logged and swallowed *any* exception (a malformed webhook secret, a non-Hash JSON payload, a bug in `process_event`), returning normally without halting the Rails `before_action` chain — so the controller action still ran for a request whose signature was never confirmed valid. It now calls `head :unauthorized` in that rescue, matching the existing invalid-signature path, and validates the parsed webhook payload is a `Hash` before use.
- **A blank or whitespace-only OpenAI webhook secret is no longer usable as the HMAC key.** `Coolhand::OpenAi::WebhookValidator` previously only rejected `nil`/`false`, so `webhook_secret = ""` (e.g. an unset `ENV` var with a blank default) silently signed and verified requests with an empty key — a much weaker, easy-to-guess bypass than the already-known "secret not configured" path. It now uses the same `Coolhand.required_field?` blank-check used elsewhere in the gem.
- **`Cookie`/`Set-Cookie` headers are now redacted**, alongside the existing key/token/secret/signature/authorization patterns. Forwarding a Rails session cookie (a bearer credential) to Coolhand — e.g. via `LoggerService#forward_webhook(headers: request.headers)`, the pattern this gem's own docs show — was previously possible.
- **`BaseInterceptor.sanitize_url` now redacts a broader set of credential-shaped query parameters** (`sig`, `credential`, `password`, `auth`, in addition to the existing `key`/`token`/`secret`), matching the pattern-based approach already used for headers instead of a small exact-match list. This covers AWS SigV4 (`X-Amz-Signature`, `X-Amz-Credential`) and Google Cloud (`X-Goog-Signature`, `X-Goog-Credential`) presigned-URL parameters that were previously logged in full.
- **A failure capturing an intercepted request's body (e.g. an already-consumed `body_stream`) no longer prevents the real request from being attempted.** The capture happened before any error handling was in place, so an exception there escaped `NetHttpInterceptor#request` entirely — the host app's actual LLM call never happened. It's now rescued, logged, and treated as "body unavailable," and the real request still proceeds.
- **Streamed response bodies are no longer buffered into a thread-local for requests this gem never intercepted.** `ResponseInterceptor#read_body` previously buffered every block-form `read_body` call process-wide, regardless of whether the enclosing request matched `intercept_addresses` — an unbounded memory growth path on any thread that streams large non-LLM responses (file downloads, etc.). Buffering now only happens while a `NetHttpInterceptor#request` call is actively capturing.
- **A request made from inside another intercepted request's streaming callback no longer corrupts the outer request's logged response body.** The per-thread stream buffer is now saved and restored around each intercepted request instead of unconditionally cleared, so nested/reentrant LLM calls (e.g. a second provider call triggered from a chunk handler) no longer mix one request's content into another's log entry.
- **Coolhand's own request to its backend API is no longer re-intercepted and re-logged.** If a self-hosted `base_url` or custom `intercept_addresses` entry happens to match Coolhand's own API host, the log-shipping request itself would previously be captured and logged like any other request — which itself gets logged, recursively, without bound. It's now wrapped in `Coolhand.without_capture`.
- `Coolhand::OpenAi::WebhookValidator#webhook_secret` is no longer a public reader (it's only used internally) — reduces the chance of the raw secret ending up in error-tracker breadcrumbs or view-rendered controller state.
- `YAML.load_file` → `YAML.safe_load_file` for the gem's own bundled default-addresses/patterns YAML files — defense-in-depth against unsafe deserialization, consistent with modern Psych defaults.
- Added missing `require "openssl"` (`WebhookValidator`) and `require "stringio"` (`NetHttpInterceptor`) instead of relying on both being transitively loaded by something else first.

### Fixed
- **Vertex batch result logging** — `Coolhand::Vertex::BatchResultProcessor` now sends a fully-qualified URL (`https://aiplatform.googleapis.com/v1/<resource name>`) instead of the bare Vertex job resource name, plus explicit `source_api` and `model` values, all inside `raw_request`. The Coolhand API treats `raw_request` as free-form JSON, so this improves the data available to its classification without depending on new top-level payload fields being accepted. Also fixed: `timestamp`/`completed_at` are now sent as proper ISO 8601 strings instead of raw `Time` objects, and the URL is now run through the same `sanitize_url` helper used by every other logging path in the gem, for consistency (a Vertex batch URL can't actually carry a redactable query string today, so this is defense-in-depth rather than a fix for a live leak) (#76).
- **`require "coolhand"` no longer requires `faraday`.** The gem hasn't used Faraday directly since the 0.4.0 unified `NetHttpInterceptor`, but a stale top-level `require "faraday"` meant loading the gem could raise `LoadError` for anyone without faraday installed — it was never a declared dependency. If your app relied on `require "coolhand"` transitively loading Faraday, require it yourself.
- `Coolhand::Vertex::BatchResultProcessor`, `Coolhand::OpenAi::BatchResultProcessor`, and `Coolhand::OpenAi::WebhookValidator` can now each be required independently (e.g. `require "coolhand/vertex/batch_result_processor"`) without first requiring `"coolhand"` — previously this could raise `NameError` depending on load order.
- `Coolhand::BaseInterceptor.send_complete_request_log` now runs `request_headers`/`response_headers` through `sanitize_headers` itself, rather than trusting every caller to have pre-sanitized them. `NetHttpInterceptor` already sanitized before calling it (`sanitize_headers` is idempotent, so no behavior change there); this closes the gap for any future caller that forgets.
- `Coolhand::Vertex::BatchResultProcessor#handle_failed_batch` no longer raises `NoMethodError` when a failed batch's `error` field is missing or not a Hash — it now logs the batch-failure message either way instead of falling through to the generic "failed to process" catch-all.
- **README's "Request Flow" section corrected** — it previously claimed data is sent to the Coolhand API "asynchronously in a background thread" with "zero performance impact"; it's actually sent inline, after the original response is available, bounded by the 5-second timeout described in 0.5.0's Security section.

## [0.5.0] - 2026-07-30

### Changed
- **`llm_request_log_id` and `workload_id` in feedback API responses are now hashid strings, not raw integers** — the Coolhand API now returns these as hashids, matching every other external-facing identifier on the record (they previously leaked the raw integer foreign key). This gem never typed or coerced these fields (plain hashes throughout), so no code changes are required here, but if your application stores or compares `result[:llm_request_log_id]` or `result[:workload_id]` as an integer, update it to treat the value as an opaque string identifier instead. The `create_feedback`/`update_feedback` input fields (`llm_request_log_id`, `workload_hashid`) are unaffected — they still accept either a raw integer or a hashid string.
- **`id` in feedback API responses has actually been a hashid string for some time** — flagging here since it's the same category of field; no gem-level change needed since this was never typed.
- `BaseInterceptor.sanitize_headers` and `LoggerService#sanitize_headers` (used for the main request/response logging path and webhook forwarding, respectively) now share the same sensitive-header pattern instead of each maintaining its own list, so both paths redact consistently.

### Security
- **AWS Bedrock SigV4 session tokens (`X-Amz-Security-Token`) are now redacted before logging.** The interceptor's header sanitizer used a hardcoded list of known API-key header names (`api-key`, `x-api-key`, `x-goog-api-key`, `openai-api-key`) instead of a general pattern, so this header — present on requests signed with temporary/STS credentials, the common case for Bedrock — was forwarded to the Coolhand backend and printed in `debug_mode` unredacted. The sanitizer now redacts any header whose name matches `key`, `token`, `secret`, `signature`, or `authorization`, closing this and similar gaps for any current or future provider header.
- **`debug_mode`'s "skipping capture" log line no longer prints the raw URL.** When a request matched `exclude_api_patterns` while `debug_mode` was on, the log line bypassed the usual URL sanitizer, so a Gemini/Vertex `?key=...` query-param API key could be printed in full. It now goes through the same URL sanitizer as every other log line.
- **Outbound requests to the Coolhand backend now set a 5-second connect/read timeout.** Previously this call had no explicit timeout and ran inline on the same thread as the intercepted LLM request, so a slow or unreachable Coolhand endpoint (including a self-hosted `base_url`) could add Ruby's ~60s Net::HTTP default (up to ~120s total) of latency to real LLM calls made by the host app.

### Removed
- Deleted unused `BaseInterceptor` methods with no callers anywhere in the gem: `extract_response_data`, `extract_usage_metadata`, `clean_request_headers`, `clean_response_headers`. The latter two duplicated `sanitize_headers` with a narrower, case-sensitive header list and were never wired into any interceptor — dead code carrying its own security debt.

### Dependencies
- Bumped `faraday` from 2.14.2 to 2.14.3 (#73).

## [0.4.0] - 2026-06-22

### Added
- **More default intercept addresses** — Vertex AI (`aiplatform.googleapis.com`), Cloudflare AI Gateway (`gateway.ai.cloudflare.com`), AWS Bedrock OpenAI-compatible endpoint (`bedrock-runtime`), and OpenRouter (`openrouter.ai`) are now monitored out of the box with no configuration required (#66).
- **`Configuration#enabled` flag** — Set `config.enabled = false` (e.g. `config.enabled = Rails.env.production?`) to skip all patching and validation globally without restructuring your configure block (#68).
- **Feedback `creator_type` field** — Pass `creator_type: 'human'`, `'agent'`, or `'unknown'` when submitting feedback to identify who originated the feedback; matches the Coolhand API field (#67).

### Changed
- **Deferred `api_key` validation** — A missing `api_key` no longer raises at `Coolhand.configure` time. Intercepted requests are silently skipped (with a warning log) when the key is absent, so apps that boot without a key in CI or non-production environments no longer crash (#68).

### Dependencies
- Bumped `faraday` from 2.14.1 to 2.14.2 (#63).

## [0.3.0] - 2026-05-14

### 🚀 Major Changes
- **Unified Net::HTTP Interceptor** - Replaced dual interceptor architecture (Faraday + Anthropic) with a single `NetHttpInterceptor` that captures all HTTP traffic via `Module#prepend`
- **Simplified Namespace** - Removed `Coolhand::Ruby` namespace; all classes now under `Coolhand` directly (e.g., `Coolhand::FeedbackService` instead of `Coolhand::Ruby::FeedbackService`)
- **Ruby 4.0 Compatibility** - Full support for Ruby 4.0 with conditional debugger dependencies
- **Google Gemini API Support** - `generativelanguage.googleapis.com` and `:streamGenerateContent` added to default `intercept_addresses`; both `generateContent` and `streamGenerateContent` endpoints are intercepted out of the box
- **Anthropic API Support Restored** - `api.anthropic.com` added to default `intercept_addresses`; accidentally dropped during the v0.3.0 refactor that replaced `AnthropicInterceptor` with the unified `NetHttpInterceptor`
- **URL Query Parameter Sanitization** - New `sanitize_url` helper redacts sensitive query parameters (`key`, `api_key`, `apikey`, `token`, `access_token`, `secret`) before logging; protects API keys passed as URL params (common with Gemini's `?key=` pattern)

### ✨ New Features
- **GitHub Models API** - `models.github.ai` (current endpoint) and `models.inference.ai.azure.com` (deprecated endpoint) added to default `intercept_addresses`; calls routed through GitHub Copilot credentials are now captured automatically without manual configuration. Default intercept addresses are loaded from `default_intercept_addresses.yml` to make future additions a single-line YAML change.
- **`config.base_url`** - Configurable API destination for self-hosted deployments. Defaults to `https://coolhandlabs.com/api`; set to any `https://` URL to redirect logs and feedback POSTs to your own backend. `http://localhost` and `http://127.0.0.1` are also accepted for local development. Trailing slashes are normalized automatically.
- **Feedback `sentiment` field** - New string field for feedback: `'like'`, `'dislike'`, or `'neutral'`. Preferred over the boolean `like` field for richer signal.
- **Feedback `workload_hashid` field** - New string field to associate feedback with a specific workload.
- **Batch Processing Support** - New `Coolhand::OpenAi::BatchResultProcessor` and `Coolhand::Vertex::BatchResultProcessor` for logging completed async batch jobs as individual `llm_request_log` entries
- **OpenAI Webhook Validation** - New `Coolhand::OpenAi::WebhookValidator` verifies webhook signatures using HMAC-SHA256 with timing-safe comparison; lenient in development, strict in production/staging
- **WebhookInterceptor Rails Module** - `Coolhand::WebhookInterceptor` mixin for Rails controllers to validate and dispatch OpenAI batch completion webhooks automatically
- **Capture Control** - New `config.capture` global toggle (default: `true`) and `config.debug_mode` (captures locally, skips API forwarding) for fine-grained interception control
- **Thread-Safe Block Control** - `Coolhand.with_capture { }` and `Coolhand.without_capture { }` for scoped override of capture behavior within a block; uses thread-local storage
- **Exclude API Patterns** - New `config.exclude_api_patterns` deny-list checked after the `intercept_addresses` allow-list; default excludes `["/batchPredictionJobs/"]` to suppress Vertex AI batch job management noise

### 🚫 Deprecated
- **Feedback `like` field** - The boolean `like` field is deprecated. Use `sentiment: 'like'` or `sentiment: 'dislike'` instead.

### 🏗️ Architecture Improvements
- **Single Interceptor** - `NetHttpInterceptor` patches `Net::HTTP#request` and `Net::HTTPResponse#read_body`; removed ~1,400 lines of interceptor-specific code
- **Thread-Safe Streaming** - Uses `Thread.current[:coolhand_stream_buffer]` for streaming response capture
- **Capture Priority Hierarchy** - `debug_mode` (always capture) > thread-local override > global `capture` config

### 🐛 Bug Fixes
- **Streaming Response Encoding** - Streamed response content is now force-encoded to UTF-8 before JSON parsing, eliminating noisy `BINARY` encoding warnings for multi-byte responses.
- **Double-Capture with `Net::HTTP.new` Pattern** - Fixed double-logging when callers use `Net::HTTP.new(host, port).request(req)` without an explicit `start` block. The re-entry guard is now per-connection-object (using a `compare_by_identity` Hash) rather than a boolean thread-local, so independent requests on a different `Net::HTTP` instance inside a callback are still captured.
- **Provider-Neutral Readiness Log** - Startup console message no longer names a single provider; it now reflects all monitored inference URIs.
- **Interceptor No Longer Silently Drops Logs on HTTP Errors** - Wrapped `Net::HTTP#request` in `begin/rescue/ensure` so `send_complete_request_log` is always called even when the SDK raises an exception (e.g., `Anthropic::Errors::NotFoundError` on a 404). Status is extracted from the exception via `.status`, `.response.status`, or message parsing.

### 📦 Dependencies
- Bumped `faraday` from 2.14.0 to 2.14.1

### 💔 Breaking Changes
- **`config.base_url` validation** - `Coolhand.configure` now raises `Coolhand::Error` if `base_url` is set to a plain `http://` URL (non-localhost). Previously any string was accepted silently. If you were pointing at an internal `http://` host (e.g. `http://logs.internal/api`), you will need to either enable TLS on that host or use an `https://` proxy in front of it.
- **Namespace Change** - `Coolhand::Ruby::*` references must be updated to `Coolhand::*`
- **Removed Files** - `faraday_interceptor.rb` and `anthropic_interceptor.rb` replaced by `net_http_interceptor.rb`
- **`environment` Config Behavior** - The `environment` attribute no longer controls whether requests are forwarded to the API. Use `config.debug_mode = true` instead if you previously relied on `environment: "development"` to suppress API calls.

### 🔄 Migration Guide
1. Update gem dependency to `~> 0.3.0`
2. Replace `Coolhand::Ruby::` with `Coolhand::` in all class references
3. If using `environment: "development"` to prevent API calls, switch to `config.debug_mode = true`
4. If `config.base_url` was set to a plain `http://` (non-localhost) URL, switch to `https://` or use an `https://` proxy
5. No other changes needed to `Coolhand.configure` blocks for basic usage

## [0.2.0] - 2025-12-16

### ✨ Major New Features
- **Official Anthropic Gem Support** - Added comprehensive monitoring support for the official `anthropic` gem (v1.8+) through direct Net::HTTP interception
- **Dual Gem Compatibility** - Support for both `anthropic` (official) and `ruby-anthropic` (community) gems with automatic detection and appropriate interceptor selection
- **Streaming Response Support** - Enhanced SSE (Server-Sent Events) parsing for Anthropic streaming responses with proper message accumulation and reconstruction
- **Graceful Gem Conflict Handling** - Automatic detection when both anthropic gems are installed, with graceful degradation to ruby-anthropic monitoring

### 🏗️ Architecture Improvements
- **AnthropicInterceptor Module** - New dedicated interceptor for official anthropic gem requests with streaming response support
- **BaseInterceptor Module** - Shared functionality across interceptors with unified API logging format and DRY principles
- **Modular Design** - Moved from single `interceptor.rb` to specialized interceptors (`faraday_interceptor.rb`, `anthropic_interceptor.rb`)
- **Enhanced Configuration** - Automatic gem detection in `configure` block with appropriate interceptor selection

### 🔧 API & Format Changes
- **Unified Logging Format** - Standardized API request/response logging with `raw_request` wrapper and collector data integration
- **Headers Field Update** - API logs now use `headers` instead of `request_headers` for consistency
- **Silent Mode Override** - Critical warnings (like gem conflicts) now always display regardless of silent mode settings

### 🧪 Testing & Quality
- **Comprehensive Test Coverage** - Added 16 new specs covering all interceptor scenarios including gem conflict handling
- **RuboCop Compliance** - Applied linting with proper line length, verified doubles, and RSpec best practices
- **Thread Safety** - Enhanced request correlation with thread-local storage for streaming requests

### 🗂️ Supported Environments
- **Development Environment** - Uses official `anthropic` gem for Net::HTTP-based requests
- **AR_Dev Environment** - Uses `ruby-anthropic` gem for Faraday-based requests
- **Automatic Detection** - Coolhand detects which gem is loaded and applies appropriate interception

### 💔 Breaking Changes
- **Removed** - `lib/coolhand/ruby/interceptor.rb` replaced by specialized interceptor modules
- **API Change** - Logging format now uses `headers` field instead of `request_headers`

### 🔄 Migration Guide
For users upgrading from v0.1.x:
- No code changes required for basic usage
- If depending on old `interceptor.rb` directly, update imports to use `faraday_interceptor.rb` or `anthropic_interceptor.rb`
- API log consumers should expect `headers` field instead of `request_headers`

### 📊 Compatibility Matrix
| Gem | Version | Interceptor | Status |
|-----|---------|-------------|--------|
| `anthropic` | 1.8+ | AnthropicInterceptor | ✅ Full Support |
| `ruby-anthropic` | 0.4+ | FaradayInterceptor | ✅ Full Support |
| Both gems | Any | FaradayInterceptor | ⚠️ Graceful Degradation |

## [0.1.5] - 2024-12-09

### 🐛 Critical Bug Fixes
- **Fixed SystemStackError with APM tools** - Resolved critical conflict with Datadog and other APM tools that caused applications to crash on startup with "stack level too deep" error
- **Replaced alias_method with prepend** - Changed monkey-patching approach from `alias_method` to `prepend` for better compatibility with other instrumentation libraries
- **Added duplicate interceptor prevention** - Ensures only one Coolhand interceptor is added to each Faraday connection

## [0.1.3] - 2024-10-23

### ✨ New Features
- **Collector Identifier** - Added collector field to all API calls to identify SDK version (format: `coolhand-ruby-X.Y.Z`)
- **Collection Method Tracking** - Support for optional collection method suffix (`manual`, `auto-monitor`)

### 🏗️ Internal Improvements
- **Added Collector Module** - New `Coolhand::Collector` module for generating SDK identification strings
- **Updated ApiService** - Base service now automatically adds collector field to all API payloads
- **Enhanced Logging** - Both LoggerService and FeedbackService now send collector information

## [0.1.2] - 2024-10-22

### 🔧 Configuration Improvements
- **Removed environment variable dependency** - Configuration now only via Ruby config block
- **Added smart defaults** - Automatically monitors OpenAI and Anthropic APIs by default

### 📚 Documentation
- **Improved examples** - Added Rails credentials best practices
- **Clearer configuration** - Removed confusing ENV references

### 🐛 Bug Fixes
- **Fixed test isolation** - Added configuration reset between tests
- **Fixed intercept_addresses format** - Corrected to use array instead of string

## [0.1.1] - 2024-10-21

### ✨ New Features
- **Feedback API Support** - Users can now submit feedback (likes/dislikes, explanations, revised outputs) for LLM responses
- **Public create_feedback method** - Exposed in FeedbackService for direct feedback submission

### 🏗️ DRYer Architecture
- **Introduced ApiService base class** - Extracted common API functionality into a shared parent class, reducing code duplication
- **Renamed Logger to LoggerService** - Better naming consistency and inheritance from ApiService
- **Added FeedbackService** - New service for submitting LLM request feedback through the API

### 🔧 Development Dependencies
- **Added webmock gem** - Required for HTTP stubbing in tests

### Changed
- Updated gem name from "coolhand-ruby" to "coolhand"

## [0.1.0] - 2024-10-21

### Added
- Initial release of coolhand gem
- Automatic interception and logging of LLM API calls
- Net::HTTP patching to capture request and response data
- Support for Ruby 3.0 and higher