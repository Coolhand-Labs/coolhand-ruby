# ElevenLabs Integration Guide

This guide explains how to integrate Coolhand with ElevenLabs Conversational AI, including webhook capture and feedback submission from the widget.

## Table of Contents
- [Overview](#overview)
- [Webhook Integration](#webhook-integration)
- [Feedback Collection](#feedback-collection)
- [Complete Example](#complete-example)

## Overview

ElevenLabs Conversational AI provides voice-based AI assistants. This integration allows you to:
1. Capture conversation data via webhooks
2. Fetch and submit user feedback to Coolhand
3. Track conversation quality and user satisfaction

## Webhook Integration

### Setting Up Webhook Capture

ElevenLabs sends webhooks when conversations occur. Here's how to capture and forward them to Coolhand:

#### 1. Create a Webhook Controller

```ruby
# app/controllers/webhooks_controller.rb
class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def elevenlabs
    begin
      # Forward the webhook to Coolhand
      result = Coolhand.logger_service.forward_webhook(
        webhook_body: request.raw_post || request.body.read,
        source: "elevenlabs",
        event_type: request.headers["X-ElevenLabs-Event"] || "conversation",
        headers: request.headers
      )

      if result
        # Optionally save conversation data locally
        save_conversation_transcript(params) if params[:type] == "conversation.finished"

        render json: { status: "success" }, status: :ok
      else
        render json: { status: "error", message: "Failed to forward webhook" }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error "Webhook processing error: #{e.message}"
      render json: { status: "error", message: e.message }, status: :internal_server_error
    end
  end

  private

  def save_conversation_transcript(webhook_data)
    ConversationTranscript.create!(
      conversation_id: webhook_data.dig(:conversation, :conversation_id),
      transcript: extract_transcript(webhook_data),
      user_message: extract_user_message(webhook_data),
      assistant_message: extract_assistant_message(webhook_data),
      timestamp: Time.current
    )
  end

  def extract_transcript(data)
    transcript = data.dig(:conversation, :transcript) || []
    transcript.map { |entry| "#{entry[:role]}: #{entry[:message]}" }.join("\n")
  end

  def extract_user_message(data)
    transcript = data.dig(:conversation, :transcript) || []
    user_entries = transcript.select { |entry| entry[:role] == "user" }
    user_entries.map { |entry| entry[:message] }.join(" ")
  end

  def extract_assistant_message(data)
    transcript = data.dig(:conversation, :transcript) || []
    agent_entries = transcript.select { |entry| entry[:role] == "agent" }
    agent_entries.map { |entry| entry[:message] }.join(" ")
  end
end
```

#### 2. Configure Routes

```ruby
# config/routes.rb
Rails.application.routes.draw do
  post "webhooks/elevenlabs", to: "webhooks#elevenlabs"
end
```

#### 3. Configure Coolhand for ElevenLabs

```ruby
# config/initializers/coolhand.rb
Coolhand.configure do |config|
  config.api_key = ENV["COOLHAND_API_KEY"]
  config.environment = Rails.env
  config.silent = false

  # Include ElevenLabs API in intercept addresses
  config.intercept_addresses = [
    "api.openai.com",
    "api.anthropic.com",
    "api.elevenlabs.io"
  ]
end
```

## Feedback Collection

### Fetching Feedback from ElevenLabs API

ElevenLabs stores conversation feedback in the metadata field. Here's how to retrieve and submit it to Coolhand:

#### 1. Create ElevenLabs API Service

```ruby
# app/services/elevenlabs_api_service.rb
require 'net/http'
require 'uri'
require 'json'

class ElevenlabsApiService
  BASE_URL = 'https://api.elevenlabs.io'
  API_KEY = ENV['ELEVENLABS_API_KEY']

  def initialize
    unless API_KEY
      raise "ElevenLabs API key is required. Please set ELEVENLABS_API_KEY environment variable."
    end
  end

  # Fetch conversation data from ElevenLabs
  def fetch_conversation(conversation_id)
    url = "#{BASE_URL}/v1/convai/conversations/#{conversation_id}"
    uri = URI(url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request['xi-api-key'] = API_KEY
    request['Content-Type'] = 'application/json'

    response = http.request(request)

    if response.code == '200'
      JSON.parse(response.body)
    else
      Rails.logger.error "ElevenLabs API error: #{response.code} - #{response.body}"
      raise "Failed to fetch conversation: #{response.code}"
    end
  rescue => e
    Rails.logger.error "Error fetching conversation from ElevenLabs: #{e.message}"
    raise e
  end

  # Extract feedback data from conversation response
  def extract_feedback(conversation_data)
    feedback_data = {}

    # Feedback is located in metadata.feedback
    if conversation_data.dig('metadata', 'feedback')
      feedback = conversation_data['metadata']['feedback']

      # Extract rating (numerical score)
      if feedback['rating']
        feedback_data[:feedback_rating] = feedback['rating']
      end

      # Extract comment (text feedback)
      if feedback['comment'] && !feedback['comment'].empty?
        feedback_data[:feedback_text] = feedback['comment']
      end
    end

    # Return nil if no feedback found
    return nil if feedback_data.empty?

    feedback_data
  rescue => e
    Rails.logger.error "Error extracting feedback: #{e.message}"
    nil
  end
end
```

#### 2. Create Feedback Controller

```ruby
# app/controllers/transcripts_controller.rb
class TranscriptsController < ApplicationController
  def index
    @transcripts = ConversationTranscript.order(timestamp: :desc)
  end

  def fetch_feedback
    conversation_id = params[:conversation_id]

    begin
      # Initialize ElevenLabs API service
      elevenlabs_service = ElevenlabsApiService.new

      # Fetch conversation data from ElevenLabs
      conversation_data = elevenlabs_service.fetch_conversation(conversation_id)

      # Extract feedback from the response
      feedback_data = elevenlabs_service.extract_feedback(conversation_data)

      if feedback_data
        # Submit feedback to Coolhand using llm_provider_unique_id for matching
        coolhand_feedback = {
          like: feedback_data[:feedback_rating],
          explanation: feedback_data[:feedback_text],
          llm_provider_unique_id: conversation_id # Important: use this field for matching
        }

        result = Coolhand.feedback_service.create_feedback(coolhand_feedback)

        if result
          flash[:success] = "Feedback successfully fetched from ElevenLabs and submitted to Coolhand!"
        else
          flash[:error] = "Failed to submit feedback to Coolhand"
        end
      else
        flash[:warning] = "No feedback found for this conversation in ElevenLabs"
      end

    rescue => e
      flash[:error] = "Error fetching feedback: #{e.message}"
    end

    redirect_to transcripts_path
  end
end
```

#### 3. Create UI for Feedback Submission

```erb
<!-- app/views/transcripts/index.html.erb -->
<div class="container">
  <h1>Voice Chat Transcripts</h1>

  <% if @transcripts.any? %>
    <div class="transcripts-list">
      <% @transcripts.each do |transcript| %>
        <div class="transcript-item">
          <div class="transcript-header">
            <div class="header-info">
              <strong>Conversation ID:</strong> <%= transcript.conversation_id %>
              <span class="timestamp"><%= transcript.timestamp&.strftime("%m/%d/%Y %I:%M %p") %></span>
            </div>
            <div class="header-actions">
              <%= form_with url: "/transcripts/fetch_feedback", method: :post, local: true do |form| %>
                <%= form.hidden_field :conversation_id, value: transcript.conversation_id %>
                <%= form.submit "Fetch Feedback", class: "btn btn-primary btn-sm" %>
              <% end %>
            </div>
          </div>

          <% if transcript.transcript.present? %>
            <div class="message full-transcript">
              <span class="label">Transcript:</span> <%= transcript.transcript %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
  <% end %>
</div>
```

## Complete Example

### Full Rails Integration

Here's a complete example showing how all the pieces work together:

#### 1. Database Migration

```ruby
# db/migrate/xxx_create_conversation_transcripts.rb
class CreateConversationTranscripts < ActiveRecord::Migration[7.0]
  def change
    create_table :conversation_transcripts do |t|
      t.string :conversation_id, null: false
      t.text :transcript
      t.text :user_message
      t.text :assistant_message
      t.datetime :timestamp
      t.timestamps
    end

    add_index :conversation_transcripts, :conversation_id, unique: true
  end
end
```

#### 2. Model

```ruby
# app/models/conversation_transcript.rb
class ConversationTranscript < ApplicationRecord
  validates :conversation_id, presence: true, uniqueness: true
end
```

#### 3. ElevenLabs Widget Integration

```html
<!-- app/views/home/index.html.erb -->
<div id="voice-chat-container">
  <!-- ElevenLabs Conversational AI Widget -->
  <elevenlabs-convai agent-id="YOUR_AGENT_ID"></elevenlabs-convai>
</div>

<script src="https://unpkg.com/@elevenlabs/convai-widget-embed" async type="text/javascript"></script>
```

## Key Points

### Webhook Best Practices

1. **Always forward raw webhook data**: Use `request.raw_post` to preserve the original payload
2. **Include headers**: ElevenLabs headers contain important metadata
3. **Set source as "elevenlabs"**: This helps Coolhand properly categorize the data
4. **Handle errors gracefully**: Log errors but always return 200 OK to prevent webhook retries

### Feedback Matching

1. **Use `llm_provider_unique_id`**: This field allows matching by the ElevenLabs conversation ID
2. **Don't use `llm_request_log_id`** unless you have the actual Coolhand log ID
3. **Feedback location**: Look for feedback in `metadata.feedback` in the API response

### Data Structure

ElevenLabs feedback structure in API response:
```json
{
  "metadata": {
    "feedback": {
      "type": "rating",
      "rating": 2,
      "comment": "didn't work",
      "likes": 0,
      "dislikes": 0
    }
  }
}
```

### Environment Variables

Required environment variables:
```bash
COOLHAND_API_KEY=your_coolhand_api_key
ELEVENLABS_API_KEY=your_elevenlabs_api_key
```

## Troubleshooting

### Common Issues

1. **Webhook not being received**
   - Verify your webhook URL is publicly accessible
   - Check ElevenLabs dashboard for webhook configuration
   - Look for errors in Rails logs

2. **Feedback not found**
   - Ensure the user actually provided feedback in the widget
   - Check that conversation ID is correct
   - Verify API key has proper permissions

3. **Coolhand submission fails**
   - Use `llm_provider_unique_id` instead of `llm_request_log_id`
   - Ensure Coolhand API key is valid
   - Check that feedback data is properly formatted

### Testing

Test the integration in Rails console:
```ruby
# Test ElevenLabs API connection
service = ElevenlabsApiService.new
conversation_id = "conv_xxx"
response = service.fetch_conversation(conversation_id)
feedback = service.extract_feedback(response)

# Test Coolhand submission
coolhand_feedback = {
  like: feedback[:feedback_rating],
  explanation: feedback[:feedback_text],
  llm_provider_unique_id: conversation_id
}
result = Coolhand.feedback_service.create_feedback(coolhand_feedback)
```

## Support

For issues specific to:
- **Coolhand Ruby Gem**: [GitHub Issues](https://github.com/your-org/coolhand-ruby)
- **ElevenLabs API**: [ElevenLabs Documentation](https://docs.elevenlabs.io)
- **Integration Questions**: Contact your Coolhand support team