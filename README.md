# Coolhand Ruby Monitor

Monitor and log LLM API calls from multiple providers (OpenAI, Anthropic, Google AI, Cohere, and more) to the Coolhand analytics platform.

## Installation

```ruby
gem 'coolhand'
```

## Getting Started

1. **Get API Key**: Visit [coolhand.io](https://coolhand.io/) to create a free account
2. **Install**: `gem install coolhand`
3. **Initialize**: Add configuration to your Ruby application
4. **Configure**: Set your API key in the configuration block
5. **Deploy**: Your AI calls are now automatically monitored!

## Quick Start

### Automatic Global Monitoring

🔥 **Set it and forget it! Monitor ALL AI API calls across your entire application with minimal configuration.**

```ruby
# Add this configuration at the start of your application
require 'coolhand/ruby'

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
require 'coolhand/ruby'

# Create feedback for an LLM response
feedback_service = Coolhand::Ruby::FeedbackService.new(Coolhand.configuration)

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
    feedback_service = Coolhand::Ruby::FeedbackService.new(Coolhand.configuration)

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
    feedback_service = Coolhand::Ruby::FeedbackService.new(Coolhand.configuration)

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
require 'coolhand/ruby'

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

### With Anthropic Ruby Client

```ruby
require 'anthropic'
require 'coolhand/ruby'

# Configure Coolhand
Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'
end

# Use Anthropic normally - requests are automatically logged
anthropic = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])

response = anthropic.messages(
  model: "claude-3-opus",
  max_tokens: 1024,
  messages: [{ role: "user", content: "Hello, Claude!" }]
)

puts response["content"]
# Automatically logged to Coolhand!
```

## What Gets Logged

The monitor captures:

- **Request Data**: Method, URL, headers, request body
- **Response Data**: Status code, headers, response body
- **Metadata**: Timestamp, protocol used
- **LLM-Specific**: Model used, token counts, temperature settings

Headers containing API keys are automatically sanitized for security.

## Supported Libraries

The monitor works with any Ruby library that uses Faraday for HTTP(S) requests to LLM APIs, including:

- OpenAI Ruby SDK
- Anthropic Ruby SDK
- ruby-openai gem
- LangChain.rb
- Direct Faraday requests
- Any other Faraday-based HTTP client

## How It Works

The gem patches Faraday connections to intercept HTTP requests. When a request matches the configured LLM endpoints:

1. The original request executes normally
2. Request and response data (body, headers, status) are captured
3. Data is sent to the Coolhand API asynchronously in a background thread
4. Your application continues without any performance impact

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
require 'coolhand/ruby'

Coolhand.configure do |config|
  config.api_key = 'your_api_key_here'  # Store securely, don't commit to git
  config.environment = 'production'
  config.silent = false
end

# Your application code here...
```

## API Key

🆓 **Sign up for free** at [coolhand.io](https://coolhand.io/) to get your API key and start monitoring your LLM usage.

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

## Security

- API keys in request headers are automatically redacted
- No sensitive data is exposed in logs
- All data is sent via HTTPS to Coolhand servers

## Other Languages

- **Node.js**: [coolhand-node package](https://github.com/coolhand-io/coolhand-node) - Coolhand monitoring for Node.js applications
- **API Docs**: [API Documentation](https://coolhand.io/docs) - Direct API integration documentation

## Community

- **Questions?** [Create an issue](https://github.com/Coolhand-Labs/coolhand-ruby/issues)
- **Contribute?** [Submit a pull request](https://github.com/Coolhand-Labs/coolhand-ruby/pulls)
- **Support?** Visit [coolhandlabs.com](https://coolhandlabs.com)

## License

Apache-2.0
