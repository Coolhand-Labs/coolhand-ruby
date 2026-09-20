# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in coolhand-ruby.gemspec
gemspec

gem "faraday-typhoeus", "~> 1.1"
gem "ruby-openai", "~> 8.3"
gem "anthropic", "~> 0.3"

group :development, :test do
  gem "bundler-audit", "~> 0.9", require: false
  gem "simplecov", require: false
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.12"
  gem "rubocop", "~> 1.62"
  gem "rubocop-performance", "~> 1.23", require: false
  gem "rubocop-rspec", "~> 3.4.0", require: false
  gem "test-prof", "~> 1.4.4"
  gem "webmock", "~> 3.19"

  gem "pry"

  # debug (not pry-byebug) so one Gemfile.lock is valid on every Ruby in the CI matrix,
  # including 4.0, which byebug doesn't support yet.
  gem "debug"
end
