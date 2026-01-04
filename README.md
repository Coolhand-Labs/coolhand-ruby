# Coolhand Ruby Monitor

Monitor and log LLM API calls from multiple providers (OpenAI, Anthropic, Google AI, Cohere, and more) to the Coolhand analytics platform.

## Installation

```ruby
gem 'coolhand'
```

## Getting Started

1. **Get API Key**: Visit [coolhandlabs.com](https://coolhandlabs.com/) to create a free account
2. **Install**: `gem install coolhand`
3. **Initialize**: Add configuration to your Ruby application
4. **Configure**: Set your API key in the configuration block
5. **Deploy**: Your AI calls are now automatically monitored!

## Quick Start

### Automatic Global Monitoring

🔥 **Set it and forget it! Monitor ALL AI API calls across your entire application with minimal configuration.**

```ruby
# Add this configuration at the start of your application
require 'coolhand'

Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'
  config.silent = true  # Set to false for debug output
end

# That's it! ALL AI API calls are now automatically monitored:
# ✅ OpenAI SDK calls
# ✅ Anthropic API calls
# ✅ Direct HTTP requests to AI APIs
# ✅ ANY library making AI API calls via Faraday

# NO code changes needed in your existing services!
```

**✨ Why Automatic Monitoring:**
- 🚫 **Zero refactoring** - No code changes to existing services
- 📊 **Complete coverage** - Monitors ALL AI libraries using Faraday automatically
- 🔒 **Security built-in** - Automatic credential sanitization
- ⚡ **Performance optimized** - Negligible overhead via async logging
- 🛡️ **Future-proof** - Automatically captures new AI calls added by your team

## Feedback API

Collect feedback on LLM responses to improve model performance:

```ruby
require 'coolhand'

# Create feedback for an LLM response
feedback_service = Coolhand::FeedbackService.new(Coolhand.configuration)

feedback = feedback_service.create_feedback(
  llm_request_log_id: 123,
  llm_provider_unique_id: 'req_xxxxxxx',
  client_unique_id: 'workorder-chat-456',
  creator_unique_id: 'user-789',
  original_output: 'Here is the original LLM response!',
  revised_output: 'Here is the human edit of the original LLM response.',
  explanation: 'Tone of the original response read like AI-generated open source README docs',
  like: true
)
```

**Field Guide:** All fields are optional, but here's how to get the best results:

### Matching Fields
- **`llm_request_log_id`** 🎯 *Exact Match* - ID from the Coolhand API response when the original LLM request was logged. Provides exact matching.
- **`llm_provider_unique_id`** 🎯 *Exact Match* - The x-request-id from the LLM API response (e.g., "req_xxxxxxx")
- **`original_output`** 🔍 *Fuzzy Match* - The original LLM response text. Provides fuzzy matching but isn't 100% reliable.
- **`client_unique_id`** 🔗 *Your Internal Matcher* - Connect to an identifier from your system for internal matching

### Quality Data
- **`revised_output`** ⭐ *Best Signal* - End user revision of the LLM response. The highest value data for improving quality scores.
- **`explanation`** 💬 *Medium Signal* - End user explanation of why the response was good or bad. Valuable qualitative data.
- **`like`** 👍 *Low Signal* - Boolean like/dislike. Lower quality signal but easy for users to provide.
- **`creator_unique_id`** 👤 *User Tracking* - Unique ID to match feedback to the end user who created it

## Rails Integration

### Configuration

Create an initializer file at `config/initializers/coolhand.rb`:

```ruby
# config/initializers/coolhand.rb
Coolhand.configure do |config|
  # Your Coolhand API Key (Required)
  # Best practice: Use Rails credentials or environment-specific configuration
  config.api_key = Rails.application.credentials.coolhand_api_key

  # Set to true to suppress console output
  config.silent = Rails.env.production?

  # Specify which LLM endpoints to intercept (array of strings)
  # Optional - defaults to ["api.openai.com", "api.anthropic.com"]
  # config.intercept_addresses = ["api.openai.com", "api.anthropic.com", "api.cohere.ai"]
end
```

### Rails Controller Example

```ruby
class ChatController < ApplicationController
  def create_feedback
    feedback_service = Coolhand::FeedbackService.new(Coolhand.configuration)

    feedback = feedback_service.create_feedback(
      llm_request_log_id: params[:log_id],
      creator_unique_id: current_user.id,
      original_output: params[:original_response],
      revised_output: params[:edited_response],
      explanation: params[:feedback_text],
      like: params[:thumbs_up]
    )

    if feedback
      render json: { success: true, message: 'Feedback recorded' }
    else
      render json: { success: false, message: 'Failed to record feedback' }, status: 422
    end
  end
end
```

### Background Job Example

```ruby
class FeedbackCollectionJob < ApplicationJob
  def perform(feedback_data)
    feedback_service = Coolhand::FeedbackService.new(Coolhand.configuration)

    feedback_service.create_feedback(
      llm_provider_unique_id: feedback_data[:request_id],
      creator_unique_id: feedback_data[:user_id],
      original_output: feedback_data[:original],
      explanation: feedback_data[:reason],
      like: feedback_data[:positive]
    )
  end
end
```

## Configuration Options

### Configuration Parameters

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `api_key` | String | *required* | Your Coolhand API key for authentication |
| `silent` | Boolean | `false` | Whether to suppress console output |
| `intercept_addresses` | Array | `["api.openai.com", "api.anthropic.com"]` | Array of API endpoint strings to monitor |

## Usage Examples

### With OpenAI Ruby Client

```ruby
require 'openai'
require 'coolhand'

# Configure Coolhand
Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'
end

# Use OpenAI normally - requests are automatically logged
client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])

response = client.chat(
  parameters: {
    model: "gpt-3.5-turbo",
    messages: [{ role: "user", content: "These pretzels are making me thirsty!"}],
    temperature: 0.7
  }
)

puts response.dig("choices", 0, "message", "content")
# The request and response have been automatically logged to Coolhand!
```

📖 **[Complete Anthropic Integration Guide →](docs/anthropic.md)** - Supports both official and community gems with automatic detection

## Logging Inbound Webhooks

For inbound webhooks (like audio transcripts or tool calls), the automatic interceptor won't capture them since they're incoming requests TO your application. In these cases, use the simple `forward_webhook` helper method:

### Webhook Forwarding Example (Recommended)

```ruby
class WebhooksController < ApplicationController
  def elevenlabs
    raw_body = request.body.read
    webhook_data = JSON.parse(raw_body)

    # Forward to Coolhand with automatic field generation and binary filtering
    Thread.new do
      Coolhand.logger_service.forward_webhook(
        webhook_body: webhook_data,        # Required: webhook payload
        source: "elevenlabs",              # Required: service name
        event_type: webhook_data["type"],  # Optional: e.g., post_call_transcription
        headers: request.headers,          # Optional & recommended
      )
    end

    render json: { status: "success" }
  end
end
```

**Required Parameters:**
- `webhook_body` - The webhook payload (Hash or parsed JSON)
- `source` - Service name (String, e.g., "elevenlabs", "stripe", "twilio")

**Optional Parameters:**
- `event_type` - Event type to append to URL (e.g., "post_call_transcription" → `webhook://elevenlabs/post_call_transcription`)
- `headers` - Request headers (automatically sanitized)
- `conversation_id`, `agent_id`, `metadata` - Custom fields for your tracking needs

**Error Handling:**
- **Silent mode = false**: Raises `ArgumentError` if required parameters are missing
- **Silent mode = true**: Logs warning and returns `false` if required parameters are missing

That's it! The `forward_webhook` method automatically:
- ✅ Generates unique ID and timestamp
- ✅ Filters out binary data (audio, images, etc.)

## What Gets Logged

The monitor captures:

- **Request Data**: Method, URL, headers, request body
- **Response Data**: Status code, headers, response body
- **Metadata**: Timestamp, protocol used
- **LLM-Specific**: Model used, token counts, temperature settings

Headers containing API keys are automatically sanitized for security.

## Binary Data Filtering

**Coolhand does not track or store binary data.** The gem automatically filters out:

- Audio files and data (`audio`, `audio_data`, `full_audio`, `raw_audio`)
- Image data (`image_data`, `image_content`)
- File content (`file_content`, `binary_content`)
- Base64 encoded data (`audio_base64`, `base64_data`)
- Voice samples and audio URLs

This ensures:
- ✅ **Smaller payloads** - Only text and metadata are sent
- ✅ **Faster processing** - No bandwidth wasted on binary data
- ✅ **Privacy focused** - Audio/video content never leaves your infrastructure
- ✅ **Clean logs** - Focus on conversational data, not media files

The filtering is automatic and applies to all monitored API calls and webhook logging.

## Supported Libraries

The monitor works with multiple transport layers and Ruby libraries:

**Faraday-based libraries:**
- OpenAI Ruby SDK
- ruby-anthropic gem (community Anthropic gem)
- ruby-openai gem
- LangChain.rb
- Direct Faraday requests
- Any other Faraday-based HTTP client

**Native HTTP libraries:**
- Official Anthropic Ruby SDK (using Net::HTTP)
- Any library using Net::HTTP directly

**Auto-detection**: Coolhand automatically detects which transport layer your libraries use and applies the appropriate monitoring strategy.

## How It Works

Coolhand uses a dual-interceptor strategy to monitor different HTTP transport layers:

### Faraday Interceptor
- Patches Faraday connections using middleware injection
- Monitors: OpenAI SDK, ruby-anthropic, LangChain.rb, and other Faraday-based libraries
- Handles: Standard HTTP requests and Server-Sent Events (SSE) for streaming

### Anthropic Interceptor
- Patches the official Anthropic gem's internal HTTP transport (Net::HTTP)
- Monitors: Official Anthropic Ruby SDK requests

### Request Flow
When a request matches configured LLM endpoints:

1. The original request executes normally with zero performance impact
2. Request and response data (body, headers, status) are captured by the appropriate interceptor
3. For streaming requests, the complete accumulated response is captured (not individual chunks)
4. Data is sent to the Coolhand API asynchronously in a background thread
5. Your application continues without interruption

For non-matching endpoints, requests pass through unchanged.

## Troubleshooting

### Debugging Output

Enable verbose logging to see what's being intercepted:

```ruby
Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'
  config.silent = false  # Enable console output
end
```

### Testing

In test environments, you may want to configure differently:

```ruby
# config/initializers/coolhand.rb
if Rails.env.test?
  Coolhand.configure do |config|
    config.api_key = 'test_key'
    config.silent = true
  end
end
```

### Non-Rails Applications

For standard Ruby scripts or non-Rails applications:

```ruby
#!/usr/bin/env ruby
require 'coolhand'

Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'  # Store securely, don't commit to git
  config.environment = 'production'
  config.silent = false
end

# Your application code here...
```

## API Key

🆓 **Sign up for free** at [coolhandlabs.com](https://coolhandlabs.com/) to get your API key and start monitoring your LLM usage.

**What you get:**
- Complete LLM request and response logging
- Usage analytics and insights
- Feedback collection and quality scoring
- No credit card required to start

## Error Handling

The monitor handles errors gracefully:

- Failed API logging attempts are logged to console but don't interrupt your application
- Invalid API keys will be reported but won't crash your app
- Network issues are handled with appropriate error messages


## Batch webhook handler (OpenAI)

Automatically handle OpenAI batch event logs (batch.completed, batch.failed, batch.expired, batch.cancelled)
by intercepting webhook requests and enqueuing your batch result processor.

Usage:
- Include the interceptor in your controller:
  include Coolhand::WebhookInterceptor
- Add the before_action to validate and populate @validator payload:
  before_action :intercept_batch_request, only: :openai
- Ensure you skip CSRF for the webhook endpoint:
  skip_before_action :verify_authenticity_token

Minimal example (only key lines shown):

```ruby
# app/controllers/webhooks/batch_api_requests_controller.rb
# ...existing code...
include Coolhand::WebhookInterceptor

skip_before_action :verify_authenticity_token
before_action :intercept_batch_request, only: :openai

def openai
  event = JSON.parse(@validator.payload)
  case event["type"]
  when "batch.completed", "batch.failed", "batch.expired", "batch.cancelled"
    batch_id = event.dig("data", "id")
    batch_request = BatchApiRequest.find_by(provider: "openai", provider_batch_id: batch_id)

    if batch_request
      OpenAi::BatchResultProcessor.perform_async(batch_request.id)
      Rails.logger.info("Queued batch result processing for BatchApiRequest #{batch_request.id}")
    else
      Rails.logger.warn("Could not find BatchApiRequest for OpenAI batch ID: #{batch_id}")
    end
  else
    Rails.logger.info("Unhandled OpenAI webhook event type: #{event["type"]}")
  end

  head :ok
rescue JSON::ParserError
  head :bad_request
rescue StandardError => e
  Rails.logger.error("OpenAI webhook error: #{e.message}")
  head :internal_server_error
end
# ...existing code...
```

## Integration Guides

- **[Anthropic Integration](docs/anthropic.md)** - Complete guide for both official and community Anthropic gems, including streaming, dual gem handling, and troubleshooting
- **[ElevenLabs Integration](docs/elevenlabs.md)** - Complete guide for integrating ElevenLabs Conversational AI with webhook capture and feedback submission

## Security

- API keys in request headers are automatically redacted
- No sensitive data is exposed in logs
- All data is sent via HTTPS to Coolhand servers

## Other Languages

- **Node.js**: [coolhand-node package](https://github.com/coolhand-io/coolhand-node) - Coolhand monitoring for Node.js applications
- **API Docs**: [API Documentation](https://coolhandlabs.com/docs) - Direct API integration documentation

## Community

- **Questions?** [Create an issue](https://github.com/Coolhand-Labs/coolhand-ruby/issues)
- **Contribute?** [Submit a pull request](https://github.com/Coolhand-Labs/coolhand-ruby/pulls)
- **Support?** Visit [coolhandlabs.com](https://coolhandlabs.com)

## License

Apache-2.0
