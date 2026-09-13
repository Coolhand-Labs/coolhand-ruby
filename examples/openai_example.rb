# frozen_string_literal: true

# Live smoke test: one real OpenAI chat completion, monitored by Coolhand.
# Run: bundle exec ruby examples/openai_example.rb
# Requires: COOLHAND_API_KEY, OPENAI_API_KEY

unless ENV["COOLHAND_API_KEY"]
  puts "Skipping openai_example.rb — COOLHAND_API_KEY not set."
  exit 0
end

unless ENV["OPENAI_API_KEY"]
  puts "Skipping openai_example.rb — OPENAI_API_KEY not set."
  exit 0
end

require "coolhand"

begin
  require "openai"
rescue LoadError
  warn "The 'openai' gem isn't installed. Add `gem \"ruby-openai\"` to your Gemfile to run this example."
  exit 1
end

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_API_KEY")
  config.silent = false
end

client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

response = client.chat(
  parameters: {
    model: "gpt-3.5-turbo",
    messages: [{ role: "user", content: "Reply with a single short word." }],
    temperature: 0.7
  }
)

content = response.dig("choices", 0, "message", "content")
raise "No content in OpenAI response: #{response.inspect}" unless content

puts "OpenAI replied: #{content.strip}"
puts "Check the COOLHAND: log lines above to confirm the request was intercepted."
