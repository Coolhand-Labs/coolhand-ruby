# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### ✨ New Features
- **Google Gemini API Support** - `generativelanguage.googleapis.com` and `:streamGenerateContent` added to default `intercept_addresses`; both `generateContent` and `streamGenerateContent` endpoints are intercepted out of the box
- **Anthropic API Support Restored** - `api.anthropic.com` added to default `intercept_addresses`; accidentally dropped during the v0.3.0 refactor that replaced `AnthropicInterceptor` with the unified `NetHttpInterceptor`
- **URL Query Parameter Sanitization** - New `sanitize_url` helper redacts sensitive query parameters (`key`, `api_key`, `apikey`, `token`, `access_token`, `secret`) before logging; protects API keys passed as URL params (common with Gemini's `?key=` pattern)
- **Gemini Header Sanitization** - `x-goog-api-key` added to the sanitized headers list alongside existing OpenAI/generic keys

## [0.3.0] - 2026-03-01

### 🚀 Major Changes
- **Unified Net::HTTP Interceptor** - Replaced dual interceptor architecture (Faraday + Anthropic) with a single `NetHttpInterceptor` that captures all HTTP traffic via `Module#prepend`
- **Simplified Namespace** - Removed `Coolhand::Ruby` namespace; all classes now under `Coolhand` directly (e.g., `Coolhand::FeedbackService` instead of `Coolhand::Ruby::FeedbackService`)
- **Ruby 4.0 Compatibility** - Full support for Ruby 4.0 with conditional debugger dependencies

### ✨ New Features
- **Batch Processing Support** - New `Coolhand::OpenAi::BatchResultProcessor` and `Coolhand::Vertex::BatchResultProcessor` for logging completed async batch jobs as individual `llm_request_log` entries
- **OpenAI Webhook Validation** - New `Coolhand::OpenAi::WebhookValidator` verifies webhook signatures using HMAC-SHA256 with timing-safe comparison; lenient in development, strict in production/staging
- **WebhookInterceptor Rails Module** - `Coolhand::WebhookInterceptor` mixin for Rails controllers to validate and dispatch OpenAI batch completion webhooks automatically
- **Capture Control** - New `config.capture` global toggle (default: `true`) and `config.debug_mode` (captures locally, skips API forwarding) for fine-grained interception control
- **Thread-Safe Block Control** - `Coolhand.with_capture { }` and `Coolhand.without_capture { }` for scoped override of capture behavior within a block; uses thread-local storage
- **Exclude API Patterns** - New `config.exclude_api_patterns` deny-list checked after the `intercept_addresses` allow-list; default excludes `["/batchPredictionJobs/"]` to suppress Vertex AI batch job management noise

### 🏗️ Architecture Improvements
- **Single Interceptor** - `NetHttpInterceptor` patches `Net::HTTP#request` and `Net::HTTPResponse#read_body`; removed ~1,400 lines of interceptor-specific code
- **Thread-Safe Streaming** - Uses `Thread.current[:coolhand_stream_buffer]` for streaming response capture
- **Capture Priority Hierarchy** - `debug_mode` (always capture) > thread-local override > global `capture` config

### 🐛 Bug Fixes
- **Interceptor No Longer Silently Drops Logs on HTTP Errors** - Wrapped `Net::HTTP#request` in `begin/rescue/ensure` so `send_complete_request_log` is always called even when the SDK raises an exception (e.g., `Anthropic::Errors::NotFoundError` on a 404). Status is extracted from the exception via `.status`, `.response.status`, or message parsing.

### 📦 Dependencies
- Bumped `faraday` from 2.14.0 to 2.14.1

### 💔 Breaking Changes
- **Namespace Change** - `Coolhand::Ruby::*` references must be updated to `Coolhand::*`
- **Removed Files** - `faraday_interceptor.rb` and `anthropic_interceptor.rb` replaced by `net_http_interceptor.rb`
- **`environment` Config Behavior** - The `environment` attribute no longer controls whether requests are forwarded to the API. Use `config.debug_mode = true` instead if you previously relied on `environment: "development"` to suppress API calls.

### 🔄 Migration Guide
1. Update gem dependency to `~> 0.3.0`
2. Replace `Coolhand::Ruby::` with `Coolhand::` in all class references
3. If using `environment: "development"` to prevent API calls, switch to `config.debug_mode = true`
4. No other changes needed to `Coolhand.configure` blocks for basic usage

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