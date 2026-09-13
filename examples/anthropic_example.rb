# frozen_string_literal: true

# Live smoke test: one real Anthropic Messages call, monitored by Coolhand.
# Run: bundle exec ruby examples/anthropic_example.rb
# Requires: COOLHAND_API_KEY, ANTHROPIC_API_KEY

unless ENV["COOLHAND_API_KEY"]
  puts "Skipping anthropic_example.rb — COOLHAND_API_KEY not set."
  exit 0
end

unless ENV["ANTHROPIC_API_KEY"]
  puts "Skipping anthropic_example.rb — ANTHROPIC_API_KEY not set."
  exit 0
end

require "coolhand"

begin
  require "anthropic"
rescue LoadError
  warn "The 'anthropic' gem isn't installed. Add `gem \"anthropic\"` to your Gemfile to run this example."
  exit 1
end

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_API_KEY")
  config.silent = false
end

client = Anthropic::Client.new

response = client.messages(
  parameters: {
    model: "claude-3-5-sonnet-latest",
    max_tokens: 32,
    messages: [{ role: "user", content: "Reply with a single short word." }]
  }
)

text = response.content.first&.text
raise "No content in Anthropic response: #{response.inspect}" unless text

puts "Claude replied: #{text.strip}"
puts "Check the COOLHAND: log lines above to confirm the request was intercepted."
