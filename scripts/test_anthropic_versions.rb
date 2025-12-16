#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to test AnthropicInterceptor with different Anthropic gem versions
#
# Usage:
#   ruby scripts/test_anthropic_versions.rb
#   ruby scripts/test_anthropic_versions.rb 1.8.0
#   ruby scripts/test_anthropic_versions.rb 1.16.0

require "fileutils"
require "bundler"

class AnthropicVersionTester
  SUPPORTED_VERSIONS = {
    "1.8" => "1.8.0",
    "1.16" => "1.16.0"
  }.freeze

  def initialize(version = nil)
    @version = version || "current"
    @test_failed = false
  end

  def run
    if @version == "current"
      test_current_version
    elsif @version == "all"
      test_all_versions
    else
      test_specific_version(@version)
    end

    exit(@test_failed ? 1 : 0)
  end

  private

  def test_current_version
    puts "🧪 Testing with current Anthropic gem version (or no gem)"
    run_tests
  end

  def test_all_versions
    puts "🧪 Testing all supported Anthropic gem versions"

    SUPPORTED_VERSIONS.each_value do |full_version|
      puts "\n#{'=' * 60}"
      puts "Testing with Anthropic v#{full_version}"
      puts "=" * 60
      test_specific_version(full_version)
    end
  end

  def test_specific_version(version)
    short_version = version.split(".")[0..1].join(".")
    gemfile = "Gemfile.anthropic-#{short_version}"

    unless File.exist?(gemfile)
      puts "❌ Gemfile for version #{version} not found: #{gemfile}"
      @test_failed = true
      return
    end

    puts "🧪 Testing with Anthropic gem v#{version}"
    puts "📦 Using Gemfile: #{gemfile}"

    # Set environment variable for version-specific tests
    ENV["ANTHROPIC_VERSION"] = version
    ENV["BUNDLE_GEMFILE"] = gemfile

    begin
      # Install dependencies for this version
      puts "📥 Installing dependencies..."
      system("bundle install --quiet") || raise("Bundle install failed")

      # Run version-specific tests
      run_tests
    rescue StandardError => e
      puts "❌ Error testing version #{version}: #{e.message}"
      @test_failed = true
    ensure
      # Clean up environment
      ENV.delete("ANTHROPIC_VERSION")
      ENV.delete("BUNDLE_GEMFILE")
    end
  end

  def run_tests
    test_commands = [
      # Run the main anthropic interceptor tests
      "bundle exec rspec spec/coolhand/ruby/anthropic_interceptor_spec.rb --format documentation",

      # Run the version integration tests
      "bundle exec rspec spec/coolhand/ruby/anthropic_version_integration_spec.rb --format documentation",

      # Run a subset of tests that exercise the interceptor
      "bundle exec rspec spec/coolhand/ruby_spec.rb --format documentation"
    ]

    test_commands.each do |command|
      puts "\n🏃 Running: #{command}"
      puts "-" * 60

      success = system(command)

      unless success
        puts "❌ Test command failed: #{command}"
        @test_failed = true
        return
      end

      puts "✅ Test command passed"
    end

    puts "\n🎉 All tests passed for this version!"
  end

  def self.usage
    puts <<~USAGE
      Usage: ruby scripts/test_anthropic_versions.rb [VERSION]

      VERSION can be:
        - Specific version: 1.8.0, 1.16.0
        - Short version: 1.8, 1.16
        - "all" to test all versions
        - "current" or omitted to test with current/no gem

      Examples:
        ruby scripts/test_anthropic_versions.rb           # Test with current setup
        ruby scripts/test_anthropic_versions.rb 1.8.0     # Test with Anthropic v1.8.0
        ruby scripts/test_anthropic_versions.rb 1.16      # Test with Anthropic v1.16.x
        ruby scripts/test_anthropic_versions.rb all       # Test all supported versions
    USAGE
  end
end

# Parse command line arguments
version = ARGV[0]

if ["--help", "-h"].include?(version)
  AnthropicVersionTester.usage
  exit 0
end

# Expand short versions
version = SUPPORTED_VERSIONS[version] if version && SUPPORTED_VERSIONS.key?(version)

# Run the tests
tester = AnthropicVersionTester.new(version)
tester.run
