# Coolhand Ruby Gem Version Guide

## Version 0.3.0 - Namespace Refactoring & Unified Interceptor

### 🚨 Breaking Changes

Version 0.3.0 removes the `Ruby` namespace from the gem to simplify the API and replaces the dual interceptor architecture with a unified Net::HTTP interceptor.

### Migration Guide

#### 1. Update Require Statements

**Before (v0.2.x):**
```ruby
require 'coolhand'
```

**After (v0.3.x):**
```ruby
require 'coolhand'
```

#### 2. Update Class References

**Before (v0.2.x):**
```ruby
# FeedbackService
feedback_service = Coolhand::Ruby::FeedbackService.new

# LoggerService
logger_service = Coolhand::Ruby::LoggerService.new

# Version reference
puts Coolhand::Ruby::VERSION

# Collector module
Coolhand::Ruby::Collector.get_collector_string
```

**After (v0.3.x):**
```ruby
# FeedbackService
feedback_service = Coolhand::FeedbackService.new

# LoggerService
logger_service = Coolhand::LoggerService.new

# Version reference
puts Coolhand::VERSION

# Collector module
Coolhand::Collector.get_collector_string
```

#### 3. Configuration Remains Unchanged

Configuration usage remains the same:

```ruby
Coolhand.configure do |config|
  config.api_key = "your-api-key"
  config.environment = 'production'
  config.silent = false
end
```

### What Changed Internally

- **File Structure**: Moved all files from `lib/coolhand/ruby/` to `lib/coolhand/`
- **Namespace**: Removed `Coolhand::Ruby` module wrapper
- **Main Entry**: `lib/coolhand.rb` now directly contains the main module instead of requiring `coolhand/ruby`
- **Tests**: Updated all test files to use the new namespace
- **Documentation**: Updated README and examples

### What Stayed the Same

- **Gem Name**: Still published as `coolhand`
- **Core Functionality**: All features work exactly the same
- **Configuration API**: No changes to how you configure the gem
- **Method Signatures**: All public methods have identical signatures

### Compatibility

- **Ruby Version**: Still requires Ruby >= 3.0.0
- **Dependencies**: No changes to gem dependencies
- **Backward Compatibility**: None - this is a breaking change requiring code updates

### Why This Change?

This refactoring simplifies the API by removing unnecessary nesting. Instead of `Coolhand::Ruby::FeedbackService`, you now use the cleaner `Coolhand::FeedbackService`.

The unified Net::HTTP interceptor also simplifies the architecture - instead of maintaining separate interceptors for Faraday and Anthropic, a single interceptor now handles all HTTP traffic at the Net::HTTP level.

### Need Help?

If you encounter issues migrating, please check:

1. All `Coolhand::Ruby::` references are updated to `Coolhand::`
2. Your gem dependency is updated to `~> 0.3.0`

For additional support, please open an issue on our [GitHub repository](https://github.com/Coolhand-Labs/coolhand-ruby).