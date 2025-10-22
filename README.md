# Coolhand Ruby Gem

Intercepts and logs LLM API calls from any Ruby application that uses the `Faraday` library, and provides feedback collection for model improvement.

This gem provides automatic instrumentation for LLM calls, allowing you to monitor usage, performance, and data without changing your application code. It works through a Faraday middleware and can capture calls from OpenAI, Anthropic, Azure, and others.

## Installation

```ruby
gem 'coolhand'
```

## Configuration

### Rails Applications

Create an initializer file at `config/initializers/coolhand.rb`:

```ruby
# config/initializers/coolhand.rb

Coolhand.configure do |config|
  # Your Coolhand API Key (Required)
  config.api_key = ENV['COOLHAND_API_KEY']

  # Set to true to suppress all console output from the gem
  config.silent = Rails.env.production?

  # Specify which LLM endpoints to intercept (comma-separated)
  # Default includes common LLM providers (Optional)
  config.intercept_addresses = "https://api.openai.com,https://api.anthropic.com"
end
```

## Usage

### Automatic Interception

Once configured, the gem automatically intercepts and logs all requests to configured LLM providers:

```ruby
# Configure Coolhand first
Coolhand.configure do |config|
  config.api_key = 'your_coolhand_api_key'
end

# Use OpenAI client normally - requests are automatically logged
client = OpenAI::Client.new()

response = client.chat(
  parameters: {
    model: "gpt-3.5-turbo",
    messages: [{ role: "user", content: "These pretzels are making me thirsty!"}],
    temperature: 0.7,
  }
)

puts response.dig("choices", 0, "message", "content")
# The request and response have been automatically logged to Coolhand!
```

## Feedback API

Collect feedback on LLM responses to improve model performance:

```ruby
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

### Feedback Field Guide

All fields are optional, but here's how to get the best results:

#### Matching Fields
- **`llm_request_log_id`** 🎯 **Exact Match** - ID from the Coolhand API response when the original LLM request was logged. Provides exact matching.
- **`llm_provider_unique_id`** 🎯 **Exact Match** - The x-request-id from the LLM API response (e.g., "req_xxxxxxx")
- **`original_output`** 🔍 **Fuzzy Match** - The original LLM response text. Provides fuzzy matching but isn't 100% reliable.
- **`client_unique_id`** 🔗 **Your Internal Matcher** - Connect to an identifier from your system for internal matching

#### Quality Data
- **`revised_output`** ⭐ **Best Signal** - End user revision of the LLM response. The highest value data for improving quality scores.
- **`explanation`** 💬 **Medium Signal** - End user explanation of why the response was good or bad. Valuable qualitative data.
- **`like`** 👍 **Low Signal** - Boolean like/dislike. Lower quality signal but easy for users to provide.
- **`creator_unique_id`** 👤 **User Tracking** - Unique ID to match feedback to the end user who created it

### Example: Rails Controller

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

### Example: Background Job

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
  ...
  config.silent = false  # Enable console output
end
```

### Testing

In non-production environments, you may want to disable the gem:

```ruby
# config/initializers/coolhand.rb
unless Rails.env.production?
  Coolhand.configure do |config|
    ...
  end
end
```

## Support

For issues or questions, please visit: https://github.com/Coolhand-Labs/coolhand-ruby or [the Coolhand site](https://coolhandlabs.com)

## License

Apache-2.0