# Anthropic Integration Guide

Coolhand provides comprehensive monitoring for Anthropic's Claude API through support for both the official and community Ruby gems. This guide covers setup, usage, streaming, and troubleshooting.

## Overview

Coolhand automatically detects which Anthropic gem you're using and applies the appropriate monitoring strategy:

- **Official Anthropic Gem** (`anthropic`): Uses Net::HTTP transport, monitored via AnthropicInterceptor
- **Community Ruby-Anthropic Gem** (`ruby-anthropic`): Uses Faraday transport, monitored via FaradayInterceptor
- **Dual Installation**: Automatically handles conflicts and prevents duplicate logging

## Quick Start

### Basic Configuration

```ruby
require 'coolhand/ruby'

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
require 'coolhand/ruby'

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
require 'coolhand/ruby'

# Configure Coolhand
Coolhand.configure do |config|
  config.api_key = 'your_coolhand_api_key'
end

# Use ruby-anthropic gem normally - monitored via Faraday
client = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])

response = client.messages(
  model: "claude-3-sonnet-20240229",
  max_tokens: 1024,
  messages: [{ role: "user", content: "Hello, Claude!" }]
)

puts response.dig("content", 0, "text")
# ✅ Automatically logged via FaradayInterceptor
```

### Streaming with Ruby-Anthropic

```ruby
# Streaming works seamlessly via Faraday monitoring
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

## Dual Gem Installation

### Automatic Conflict Resolution

When both gems are installed, Coolhand automatically handles the conflict:

```ruby
require 'anthropic'        # Official gem
require 'ruby-anthropic'  # Community gem
require 'coolhand/ruby'

Coolhand.configure do |config|
  config.api_key = 'your_coolhand_api_key'
end

# ⚠️  Warning displayed:
# "Both 'anthropic' and 'ruby-anthropic' gems are installed.
#  Coolhand will only monitor ruby-anthropic (Faraday-based) requests.
#  Official anthropic gem monitoring has been disabled."
```

**Recommendation**: Use only one gem to avoid confusion. Choose based on your needs:
- **Official gem**: Latest features, official support, Net::HTTP transport
- **Community gem**: Faraday-based, may have community contributions

### Manual Conflict Resolution

To explicitly use the official gem when both are installed:

```ruby
# Temporarily hide the community gem
begin
  # Remove ruby-anthropic from the load path
  $LOAD_PATH.reject! { |path| path.include?('ruby-anthropic') }

  require 'anthropic'
  require 'coolhand/ruby'

  Coolhand.configure do |config|
    config.api_key = 'your_coolhand_api_key'
  end

  # Now only the official gem will be monitored
  client = Anthropic::Client.new
  # ... use official gem
end
```

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
  like: true,
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
# "✅ Coolhand ready - will log OpenAI and Anthropic (official gem) calls"
# "COOLHAND: ⚠️ Warning: Both 'anthropic' and 'ruby-anthropic' gems are installed..."
```

### Common Issues

#### 1. Gem Not Detected

**Problem**: Coolhand says "Anthropic gem not loaded"

**Solution**: Ensure you require the gem before configuring Coolhand:

```ruby
require 'anthropic'  # Must come before coolhand/ruby
require 'coolhand/ruby'

Coolhand.configure do |config|
  config.api_key = 'your_api_key'
end
```

#### 2. Duplicate Requests

**Problem**: Seeing requests logged twice in dashboard

**Cause**: Usually indicates both gems are installed and conflicting

**Solution**: Choose one gem and uninstall the other:

```bash
# Keep official gem
gem uninstall ruby-anthropic

# OR keep community gem
gem uninstall anthropic
```

#### 3. Missing Streaming Data

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

#### 4. Performance Concerns

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

1. **Choose One Gem**: Avoid installing both `anthropic` and `ruby-anthropic` gems
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
- **Gem Conflicts**: Check this guide's troubleshooting section