# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Added Collector Module** - New `Coolhand::Ruby::Collector` module for generating SDK identification strings
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