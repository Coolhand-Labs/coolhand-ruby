# Anthropic Integration Guide

Coolhand provides comprehensive monitoring for Anthropic's Claude API through support for both the official and community Ruby gems. This guide covers setup, usage, streaming, and troubleshooting.

## Overview

Coolhand monitors Anthropic API calls (`api.anthropic.com`) with a single `NetHttpInterceptor` that patches `Net::HTTP`. Both Ruby gems are covered with no gem-specific setup:

- **Official Anthropic Gem** (`anthropic`): Uses Net::HTTP directly, monitored via `NetHttpInterceptor`
- **Community Ruby-Anthropic Gem** (`ruby-anthropic`): Uses Faraday. Faraday's default `net_http` adapter delegates to Net::HTTP, so these calls are monitored by the same `NetHttpInterceptor`
- **Both gems installed**: Coolhand itself adds no conflict warnings or duplicate logging (see [Using Both Gems](#using-both-gems))

**Caveat:** A Faraday connection configured with a non-Net::HTTP adapter (such as `faraday-typhoeus`) bypasses `Net::HTTP` and is not covered.

## Quick Start

### Basic Configuration

```ruby
require 'coolhand'

Coolhand.configure do |config|
  config.api_key = 'your_coolhand_api_key_here'
  config.silent = true  # Set to false for debug output
end
```

That's it! All Anthropic API calls are now automatically monitored.

## Official Anthropic Gem

### Installation

```bash
gem install anthropic
# or add to Gemfile
gem 'anthropic'
```

### Basic Usage

```ruby
require 'anthropic'
require 'coolhand'

# Configure Coolhand
Coolhand.configure do |config|
  config.api_key = 'your_coolhand_api_key'
end

# Use official Anthropic gem normally
client = Anthropic::Client.new

response = client.messages(
  parameters: {
    model: "claude-3-sonnet-20240229",
    max_tokens: 1024,
    messages: [{ role: "user", content: "Hello, Claude!" }]
  }
)

puts response.content.first.text
# ✅ Request and response automatically logged to Coolhand
```

### Streaming with Official Gem

```ruby
# Streaming is automatically detected and properly logged
response = client.messages(
  parameters: {
    model: "claude-3-sonnet-20240229",
    max_tokens: 1024,
    messages: [{ role: "user", content: "Write a haiku about Ruby" }],
    stream: true  # ✅ Streaming automatically detected
  }
)

# Process streaming response
accumulated_text = ""
response.each do |chunk|
  if chunk.delta&.text
    print chunk.delta.text
    accumulated_text += chunk.delta.text
  end
end

# ✅ Complete accumulated response logged to Coolhand (not individual chunks)
```

### Advanced Configuration

```ruby
client = Anthropic::Client.new

# All parameters are automatically captured and logged
response = client.messages(
  parameters: {
    model: "claude-3-opus-20240229",
    max_tokens: 2000,
    temperature: 0.7,
    top_p: 0.9,
    system: "You are a helpful assistant specializing in Ruby programming.",
    messages: [
      { role: "user", content: "Explain Ruby metaprogramming" }
    ],
    # Streaming works automatically
    stream: true
  }
)

# ✅ All parameters (model, temperature, top_p, system, etc.) logged
```

## Community Ruby-Anthropic Gem

### Installation

```bash
gem install ruby-anthropic
# or add to Gemfile
gem 'ruby-anthropic'
```

### Basic Usage

```ruby
require 'ruby-anthropic'
require 'coolhand'

# Configure Coolhand
Coolhand.configure do |config|
  config.api_key = 'your_coolhand_api_key'
end

# Use ruby-anthropic gem normally - monitored via Faraday's default net_http adapter
client = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])

response = client.messages(
  model: "claude-3-sonnet-20240229",
  max_tokens: 1024,
  messages: [{ role: "user", content: "Hello, Claude!" }]
)

puts response.dig("content", 0, "text")
# ✅ Automatically logged via NetHttpInterceptor
```

> If your Faraday connection uses a non-Net::HTTP adapter (such as `faraday-typhoeus`), requests are not captured.

### Streaming with Ruby-Anthropic

```ruby
# Streaming is captured the same way as any other request
response = client.messages(
  model: "claude-3-sonnet-20240229",
  max_tokens: 1024,
  messages: [{ role: "user", content: "Count to 10 slowly" }],
  stream: true
)

# Process Server-Sent Events
response.each do |event|
  puts event if event.start_with?("data:")
end

# ✅ Complete conversation logged to Coolhand
```

## Using Both Gems

Coolhand does not need to choose between the gems. Monitoring happens at the `Net::HTTP` layer through a single `NetHttpInterceptor`, so it does not depend on which gem makes the request. Coolhand does not disable monitoring, print conflict warnings, or log duplicates when both gems are installed.

Both gems define an `Anthropic` namespace, so loading both in the same app can still conflict inside your own code. That is independent of Coolhand. Pick the gem that fits your needs:
- **Official gem**: Latest features, official support, Net::HTTP transport
- **Community gem**: Faraday-based (default `net_http` adapter), may have community contributions

## Rails Integration

### Initializer Setup

```ruby
# config/initializers/coolhand.rb
Coolhand.configure do |config|
  # Use Rails credentials for API key
  config.api_key = Rails.application.credentials.coolhand_api_key

  # Suppress console output in production
  config.silent = Rails.env.production?

  # Ensure Anthropic endpoints are monitored (default behavior)
  # config.intercept_addresses = ["api.openai.com", "api.anthropic.com"]
end
```

### Service Object Pattern

```ruby
# app/services/claude_chat_service.rb
class ClaudeChatService
  def initialize
    @client = Anthropic::Client.new
  end

  def generate_response(user_message, context: nil)
    messages = []
    messages << { role: "system", content: context } if context
    messages << { role: "user", content: user_message }

    response = @client.messages(
      parameters: {
        model: "claude-3-sonnet-20240229",
        max_tokens: 1500,
        messages: messages
      }
    )

    response.content.first.text
    # ✅ Automatically logged to Coolhand with all context
  end

  def stream_response(user_message)
    response = @client.messages(
      parameters: {
        model: "claude-3-sonnet-20240229",
        max_tokens: 1500,
        messages: [{ role: "user", content: user_message }],
        stream: true
      }
    )

    Enumerator.new do |yielder|
      response.each do |chunk|
        if chunk.delta&.text
          yielder << chunk.delta.text
        end
      end
    end
    # ✅ Complete streaming conversation logged
  end
end
```

### Background Job Example

```ruby
# app/jobs/claude_analysis_job.rb
class ClaudeAnalysisJob < ApplicationJob
  def perform(document_id, analysis_type)
    document = Document.find(document_id)

    client = Anthropic::Client.new

    response = client.messages(
      parameters: {
        model: "claude-3-opus-20240229",
        max_tokens: 2000,
        system: "You are an expert document analyzer.",
        messages: [
          {
            role: "user",
            content: "Analyze this document: #{document.content}"
          }
        ]
      }
    )

    document.update!(
      analysis: response.content.first.text,
      analysis_type: analysis_type
    )

    # ✅ Analysis request logged with document context
  end
end
```

## Advanced Features

### Thread-Safe Concurrent Requests

```ruby
# Coolhand handles concurrent requests safely
threads = []

10.times do |i|
  threads << Thread.new do
    client = Anthropic::Client.new

    response = client.messages(
      parameters: {
        model: "claude-3-sonnet-20240229",
        max_tokens: 500,
        messages: [{ role: "user", content: "Request #{i}" }]
      }
    )

    puts "Response #{i}: #{response.content.first.text}"
  end
end

threads.each(&:join)
# ✅ All 10 requests logged correctly without conflicts
```

### Request Correlation

Access the current request ID for correlation:

```ruby
client = Anthropic::Client.new

response = client.messages(
  parameters: {
    model: "claude-3-sonnet-20240229",
    max_tokens: 1000,
    messages: [{ role: "user", content: "Hello" }]
  }
)

# Get the request ID that was logged to Coolhand
request_id = Thread.current[:coolhand_current_request_id]
puts "Logged to Coolhand with ID: #{request_id}"

# Use this ID for feedback or debugging
feedback_service = Coolhand::FeedbackService.new(Coolhand.configuration)
feedback_service.create_feedback(
  llm_request_log_id: request_id,
  sentiment: "like",
  explanation: "Great response quality"
)
```

## Troubleshooting

### Debug Mode

Enable verbose logging to see what's being intercepted:

```ruby
Coolhand.configure do |config|
  config.api_key = 'your_api_key'
  config.silent = false  # Enable debug output
end

# Now you'll see console output like:
# "✅ Coolhand ready - will log inference calls on monitored URIs"
```

### Common Issues

#### 1. Requests Not Appearing

**Problem**: Anthropic calls are not showing up in Coolhand

**Solution**: Check the following:

- `config.silent` is `false`, so Coolhand's debug and warning output is visible while you check the rest.
- `config.api_key` is set. Intercepted requests are skipped, with a warning log, when the key is missing.
- `config.enabled` is not `false`.
- `config.capture` is not `false`, the call is not inside `Coolhand.without_capture`, and the path does not match `exclude_api_patterns`.
- The request goes to a monitored address (`api.anthropic.com` is monitored by default).
- If you use `ruby-anthropic`, the Faraday connection uses the default `net_http` adapter. A non-Net::HTTP adapter such as `faraday-typhoeus` is not covered.

#### 2. Missing Streaming Data

**Problem**: Only seeing individual chunks, not complete response

**Cause**: Custom streaming handling interfering with automatic detection

**Solution**: Let Coolhand handle streaming automatically:

```ruby
# ❌ Don't manually collect chunks for logging
response = client.messages(parameters: { stream: true })
manual_collection = ""
response.each { |chunk| manual_collection += chunk.delta.text }

# ✅ Just process chunks normally - Coolhand handles logging
response = client.messages(parameters: { stream: true })
response.each { |chunk| print chunk.delta.text }
```

#### 3. Performance Concerns

**Problem**: Worried about monitoring overhead

**Solution**: Monitoring is asynchronous and negligible:

```ruby
# Monitoring happens in background threads
# Your application performance is unaffected
require 'benchmark'

time = Benchmark.measure do
  1000.times do
    client.messages(
      parameters: {
        model: "claude-3-haiku-20240307",  # Fast model for testing
        max_tokens: 100,
        messages: [{ role: "user", content: "Hi" }]
      }
    )
  end
end

puts "Time with monitoring: #{time.real}s"
# Overhead is typically < 1ms per request
```

### Testing

#### Test Environment Setup

```ruby
# spec/spec_helper.rb or test/test_helper.rb
if Rails.env.test?
  Coolhand.configure do |config|
    config.api_key = 'test_key_do_not_send_requests'
    config.silent = true
  end
end
```

#### Mocking for Tests

```ruby
# spec/support/anthropic_mock.rb
RSpec.configure do |config|
  config.before(:each) do
    # Mock Anthropic responses to avoid real API calls
    allow_any_instance_of(Anthropic::Client).to receive(:messages).and_return(
      double(
        content: [double(text: "Mocked response")],
        model: "claude-3-sonnet-20240229"
      )
    )
  end
end
```

## Best Practices

1. **Pick One Gem**: Both `anthropic` and `ruby-anthropic` define an `Anthropic` namespace, so avoid loading both in the same app. Coolhand monitors either one
2. **Secure API Keys**: Use environment variables or Rails credentials, never commit keys
3. **Silent in Production**: Set `config.silent = true` in production environments
4. **Monitor Performance**: Use fast models (haiku) for high-frequency requests
5. **Request Correlation**: Use thread-local request IDs for debugging and feedback
6. **Streaming Efficiency**: Let Coolhand handle streaming accumulation automatically
7. **Test Safely**: Mock API responses in test environments to avoid real charges

## API Reference

For complete API documentation, see:
- [Official Anthropic Gem](https://github.com/anthropics/anthropic-sdk-ruby)
- [Community Ruby-Anthropic Gem](https://github.com/alexrudall/ruby-anthropic)
- [Coolhand Feedback API](../README.md#feedback-api)

## Support

- **Coolhand Issues**: [GitHub Issues](https://github.com/Coolhand-Labs/coolhand-ruby/issues)
- **Anthropic API**: [Anthropic Documentation](https://docs.anthropic.com/)
- **Missing Requests**: Check this guide's troubleshooting section
