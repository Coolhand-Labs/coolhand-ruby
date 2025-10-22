# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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