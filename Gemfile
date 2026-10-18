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

  # exhale (duplication/complexity gate) requires Ruby >= 3.3, but the CI matrix and the shared
  # Gemfile.lock cover older Rubies. install_if keeps it locked everywhere and installed only where it runs.
  install_if -> { Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3") } do
    gem "exhale", "~> 0.2", require: false
  end

  # No resolution-affecting Ruby-version conditionals here (use install_if, as above, never `if RUBY_VERSION`):
  # the committed Gemfile.lock is installed in frozen mode on every Ruby in the CI matrix, so the
  # Gemfile must resolve identically everywhere.
  gem "pry"
end
