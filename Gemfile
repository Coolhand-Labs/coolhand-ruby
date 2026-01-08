# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in coolhand-ruby.gemspec
gemspec

gem "faraday-typhoeus", "~> 1.1"

group :development, :test do
  gem "simplecov", require: false
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.12"
  gem "rubocop", "~> 1.62"
  gem "rubocop-performance", "~> 1.23", require: false
  gem "rubocop-rspec", "~> 3.4.0", require: false
  gem "test-prof", "~> 1.4.4"
  gem "webmock", "~> 3.19"

  gem "pry"

  # byebug doesn't support Ruby 4 yet - use built-in debug gem instead
  if RUBY_VERSION < "4.0"
    gem "pry-byebug"
  else
    gem "debug"
  end
end
