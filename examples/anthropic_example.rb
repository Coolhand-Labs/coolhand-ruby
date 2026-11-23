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

client = Anthropic::Client.new(access_token: ENV.fetch("ANTHROPIC_API_KEY"))

# Tag the call with our own id so feedback can later find this exact request.
# The id is sent as llm_request_log.client_unique_id (see docs/declared_workloads.md).
client_unique_id = "anthropic-example.#{Time.now.to_i}.1"

response = Coolhand.with_context(client_unique_id: client_unique_id) do
  declared = Coolhand::DeclaredContext.current
  raise "client_unique_id was not set inside with_context" unless declared&.fetch(:client_unique_id) == client_unique_id

  client.messages(
    parameters: {
      model: "claude-haiku-4-5-20251001",
      max_tokens: 32,
      messages: [{ role: "user", content: "Reply with a single short word." }]
    }
  )
end

text = response.dig("content", 0, "text")
raise "No content in Anthropic response: #{response.inspect}" unless text

puts "Claude replied: #{text.strip}"
raise "Coolhand did not finish sending the log" unless Coolhand.flush

puts "Logged with client_unique_id #{client_unique_id}"
puts "Check the COOLHAND: log lines above to confirm the request was intercepted."
