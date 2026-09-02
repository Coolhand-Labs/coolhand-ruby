# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`Coolhand::TemplateService`, reached via `Coolhand.template_service` — read LLM request templates back out of Coolhand**, wrapping the new `GET /api/v2/llm_request_templates` and `GET /api/v2/llm_request_templates/{id}` endpoints. `search_templates` filters on `search:`, `workload_id:`, `status:`, `include_deprecated:` and `include_system:` plus `page:`/`per:`, and returns a `Coolhand::TemplateSearchResult`: `templates` as Hashes with Symbol keys (the same shape `create_feedback` and `create_log` already return), newest first, and `pagination` as a `Coolhand::Pagination` read from the response's `X-Page`/`X-Per-Page`/`X-Total-Count`/`X-Total-Pages` headers rather than computed from the size of the page. `get_template` adds `user_prompt_pattern`/`system_prompt_pattern`, which the list omits, and reaches deprecated and system templates by id with no opt-in flag. Search is a *parameter* on the list endpoint rather than a route of its own, so this is one method, not a list/search pair. Both require the **private** API key — the public key is write-only on this API and is rejected exactly like an invalid one. **These endpoints ship in a backend change that may not yet be deployed to the Coolhand server you point at**; against one that predates it, both methods raise a `404`. See [docs/template-search.md](docs/template-search.md). (#105)
- **`Coolhand::HttpError`** — raised by the read methods on a non-2xx response, carrying `#status` and `#body` so a caller can branch on `401` vs `404` vs `504` without matching on the message text. It subclasses the existing `Coolhand::Error`, so `rescue Coolhand::Error` still catches everything this gem raises.
- **An opt-in live suite (`bundle exec rake spec:live`, `spec/live/*_live.rb`)** — exercises the template methods against a real Coolhand server with no stubbing anywhere, driven by `COOLHAND_LIVE_BASE_URL`/`COOLHAND_LIVE_API_KEY` and hard-failing if either is missing, so a missing key can never be mistaken for a passing run. It is kept out of `bundle exec rake` and `bundle exec rspec` by not matching RSpec's default file pattern, so CI — which has neither a server nor a private key — stays green without any example being marked pending or skipped. Every request it makes is a read.

### Changed
- **The read and write paths now behave differently on failure, deliberately.** The write methods (`send_llm_request_log`, `create_log`, `create_feedback`) still log a failure and return `nil`: instrumentation must never be the reason a host app falls over. The new read methods raise instead, because a caller that asked for data has to be able to tell a `404` from a timeout from a genuinely empty result. Reads also allow 60 seconds where writes allow 5. The API bounds each *statement* behind a response at 10 seconds and answers `504` past that, but a single response runs several statements, so total time is not bounded by 10s — `include_system=true` measured 7-15 seconds against a development database while returning `200` every time. A tighter read timeout would report a working endpoint as a transport failure, and would pre-empt the `504` callers are meant to see and retry.
- **`search_templates` is not a port of the `search_templates` MCP tool and does not agree with its numbers.** `log_count` here counts only directly-collected client logs — the same records `GET /api/v2/llm_request_logs?template_id=…` returns — so it excludes evals, bakeoff comparisons and synthetic logs. Templates whose workload has been archived are returned rather than hidden, so the list agrees with `get_template`, which can always fetch such a template by id.
- `Coolhand::Error` moved from `lib/coolhand.rb` into a new `lib/coolhand/errors.rb`, alongside `Coolhand::HttpError`, and is now required first. The constant, its superclass and its behaviour are unchanged.
- The GET half of `Coolhand::ApiService` lives in a new `Coolhand::ReadRequests` mixin (`lib/coolhand/read_requests.rb`), keeping the class inside this repo's 200-line budget. Two helpers were extracted from the existing POST path and are now shared by both halves (`format_error_body`, `apply_headers`). The one behaviour change on the write path is that a failed response body over 2000 characters is now truncated in the log line instead of being printed in full.

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