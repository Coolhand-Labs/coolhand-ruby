# v0.3.0 Release Notes

## What's New

**Simplified architecture with a unified Net::HTTP interceptor and cleaner namespace.**

v0.3.0 brings two major improvements: a streamlined API by removing the `Ruby` namespace, and a unified interceptor architecture that replaces the previous dual-interceptor approach with a single, more robust Net::HTTP interceptor.

***

## 🚀 Major Changes

### Unified Net::HTTP Interceptor

**Replaced dual interceptor architecture with a single, universal Net::HTTP interceptor.**

- **Single point of interception** - Instead of separate Faraday and Anthropic interceptors, all HTTP traffic is now captured at the Net::HTTP level
- **Broader coverage** - Monitors any Ruby HTTP library that uses Net::HTTP under the hood (which is most of them)
- **Simpler codebase** - Removed ~1,400 lines of interceptor-specific code
- **Streaming support** - Thread-safe streaming response capture via `read_body` interception

```ruby
# Works automatically with all these libraries:
# - OpenAI Ruby SDK
# - Official Anthropic Ruby SDK
# - ruby-anthropic gem
# - LangChain.rb
# - Any Faraday-based HTTP client
# - Any Net::HTTP-based HTTP client

Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'
end

# All LLM API calls are now automatically monitored!
```

### Simplified Namespace

**Removed the `Ruby` namespace for a cleaner API.**

| Before (v0.2.x) | After (v0.3.x) |
|-----------------|----------------|
| `Coolhand::Ruby::FeedbackService` | `Coolhand::FeedbackService` |
| `Coolhand::Ruby::LoggerService` | `Coolhand::LoggerService` |
| `Coolhand::Ruby::VERSION` | `Coolhand::VERSION` |
| `Coolhand::Ruby::Collector` | `Coolhand::Collector` |

***

## 🛡️ Technical Improvements

### How the New Interceptor Works

The unified interceptor uses Ruby's `Module#prepend` to wrap `Net::HTTP#request` and `Net::HTTPResponse#read_body`:

```
┌─────────────────────────────────────────────────────────┐
│                    Your Application                      │
├─────────────────────────────────────────────────────────┤
│  OpenAI SDK  │  Anthropic SDK  │  Faraday  │  Net::HTTP │
├─────────────────────────────────────────────────────────┤
│              Net::HTTP (Ruby stdlib)                     │
│                        ↓                                 │
│            Coolhand::NetHttpInterceptor                  │
│         (prepended to Net::HTTP#request)                 │
├─────────────────────────────────────────────────────────┤
│                   Network Layer                          │
└─────────────────────────────────────────────────────────┘
```

### Thread Safety

- Uses `Thread.current[:coolhand_stream_buffer]` for streaming response capture
- No global state - safe for multi-threaded applications
- Clean buffer management with automatic cleanup

### Ruby 4.0 Compatibility

- Tested and compatible with Ruby 4.0
- Conditional debugger dependencies (`pry-byebug` for Ruby < 4, `debug` gem for Ruby 4+)
- No changes to `Module#prepend` or `Thread.current` behavior in Ruby 4

***

## 💔 Breaking Changes

### Namespace Changes

If you were using the full namespace path, update your references:

```ruby
# Before
Coolhand::Ruby::FeedbackService.new
Coolhand::Ruby::VERSION

# After
Coolhand::FeedbackService.new
Coolhand::VERSION
```

### Removed Files

The following files have been removed and replaced by `net_http_interceptor.rb`:

- `lib/coolhand/faraday_interceptor.rb`
- `lib/coolhand/anthropic_interceptor.rb`

If you were importing these directly (not recommended), update to use the automatic interception via `Coolhand.configure`.

***

## 🔄 Migration Guide

For most users, migration is simple:

1. **Update gem version** in your Gemfile:
   ```ruby
   gem 'coolhand', '~> 0.3.0'
   ```

2. **Update any explicit namespace references** from `Coolhand::Ruby::*` to `Coolhand::*`

3. **Remove any manual interceptor imports** - the new architecture handles everything automatically

No changes needed to your `Coolhand.configure` block or general usage patterns.

***

## 📊 Compatibility

| Environment | Status |
|-------------|--------|
| Ruby 3.0+ | ✅ Full Support |
| Ruby 4.0 | ✅ Full Support |
| Rails 6+ | ✅ Full Support |
| OpenAI SDK | ✅ Automatic |
| Anthropic SDK (official) | ✅ Automatic |
| ruby-anthropic gem | ✅ Automatic |
| Faraday-based libraries | ✅ Automatic |

***

## 🔗 Resources

- **[Migration Guide](VERSIONS.md)** - Detailed migration instructions
- **[Anthropic Integration](docs/anthropic.md)** - Guide for Anthropic SDK users
- **[GitHub Issues](https://github.com/Coolhand-Labs/coolhand-ruby/issues)** - Report bugs or request features
