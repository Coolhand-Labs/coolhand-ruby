# Coolhand Ruby Gem

Intercepts and logs OpenAI API calls from any Ruby application that uses the `Faraday` library.

This gem provides automatic instrumentation for OpenAI calls, allowing you to monitor usage, performance, and data without changing your application code. It works by new Faraday Middleware class.

Installation
Add this line to your application's Gemfile:

`gem 'coolhand'`

And then execute:

`bundle install`

Or install it yourself as:

`gem install coolhand`

Usage

You must configure the gem, typically in an initializer file (e.g., config/initializers/coolhand.rb in a Rails app) or at the beginning of your script.

You need to provide your Coolhand API key.

### config/initializers/coolhand.rb

`require 'coolhand'`

```
Coolhand.configure do |config|
#### Your Coolhand API Key (Required)
    config.api_key = ENV['COOLHAND_API_KEY']
    
#### Your Coolhand API Endpoint
    config.api_endpoint = ENV['COOLHAND_API_ENDPOINT']

#### Environment can be 'local' (default) or 'production'
#### This determines which API endpoint the logs are sent to.
    config.environment = ENV['RACK_ENV'] || 'development'

#### Set to true to suppress all console output from the gem.
    config.silent = false

#### Specify a list of paths that should be interpreted.
    config.intercept_addresses = ['https://chatgpt.com/']
end
```

Once configured, the gem will automatically start monitoring HTTP/HTTPS requests. Any call made to api.openai.com will be intercepted and logged.

### Configure Coolhand first
```
Coolhand.configure do |config|
    config.api_key = 'your_coolhand_api_key'
end
```
### Now, use the OpenAI client as you normally would
```
client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])

response = client.chat(
    parameters: {
    model: "gpt-3.5-turbo",
    messages: [{ role: "user", content: "Hello, world!"}],
    temperature: 0.7,
})

puts response.dig("choices", 0, "message", "content")
```
### The request and response from the above call have been automatically logged to Coolhand!

How It Works
The gem redefines the `Net::HTTP#request` method. The new method inspects the destination of the request. If it's for api.openai.com, it executes the original request, captures the request body, response body, headers, and status, and then sends this data to the Coolhand API in a non-blocking background thread. For all other destinations, it calls the original request method without any changes.