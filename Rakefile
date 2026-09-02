# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# Signals .simplecov to drop the coverage floor for this run: the live suite drives a single
# service, and the floor is calibrated for the full unit suite.
task :enable_live_suite do
  ENV["COOLHAND_LIVE_SUITE"] = "1"
end

# Opt-in live suite: real HTTP against a real Coolhand server, no stubbing. Kept out of the
# default task because CI has neither a server nor a private key, so `rake` and `rspec` skip it
# by not matching it rather than by any example being marked pending.
desc "Run the live suite against a real Coolhand server " \
     "(needs COOLHAND_LIVE_BASE_URL and COOLHAND_LIVE_API_KEY)"
RSpec::Core::RakeTask.new(:"spec:live") do |t|
  t.pattern = "spec/live/**/*_live.rb"
end
task "spec:live": :enable_live_suite

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]
