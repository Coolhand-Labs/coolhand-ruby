# frozen_string_literal: true

# Live smoke test: one real ElevenLabs API call, monitored by Coolhand.
# Uses plain Net::HTTP (no ElevenLabs gem dependency) to also confirm
# Coolhand's Net::HTTP interception works for direct HTTP clients, not
# just SDK-wrapped ones.
# Run: bundle exec ruby examples/elevenlabs_example.rb
# Requires: COOLHAND_API_KEY, ELEVENLABS_API_KEY

unless ENV["COOLHAND_API_KEY"]
  puts "Skipping elevenlabs_example.rb — COOLHAND_API_KEY not set."
  exit 0
end

unless ENV["ELEVENLABS_API_KEY"]
  puts "Skipping elevenlabs_example.rb — ELEVENLABS_API_KEY not set."
  exit 0
end

require "coolhand"
require "net/http"
require "json"
require "uri"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_API_KEY")
  config.silent = false
end

uri = URI("https://api.elevenlabs.io/v1/voices")
request = Net::HTTP::Get.new(uri)
request["xi-api-key"] = ENV.fetch("ELEVENLABS_API_KEY")

response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
raise "ElevenLabs request failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

voices = JSON.parse(response.body)["voices"] || []
puts "ElevenLabs returned #{voices.size} voice(s)."
puts "Check the COOLHAND: log lines above to confirm the request was intercepted."
