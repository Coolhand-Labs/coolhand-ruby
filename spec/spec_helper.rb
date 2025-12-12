# frozen_string_literal: true

require "rspec"
require "webmock/rspec"

# Load the coolhand library
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "coolhand/ruby"

RSpec.configure do |config|
  # Use only the new `expect` syntax
  config.disable_monkey_patching!

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on Module and main
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Mock external HTTP calls
  config.before do
    WebMock.disable_net_connect!
  end

  config.after do
    WebMock.reset!
  end

  # Reset Coolhand state between tests
  config.before do
    Coolhand.reset_configuration!
    # Clear any patches between tests if needed
    if defined?(Coolhand::Ruby::NetHttpInterceptor)
      Coolhand::Ruby::NetHttpInterceptor.instance_variable_set(:@patched, false)
    end
  end
end

# Helper to stub Coolhand configuration
def stub_coolhand_configuration(options = {})
  config = instance_double(Coolhand::Configuration)
  default_options = {
    patch_net_http: true,
    intercept_addresses: ["api.anthropic.com", "api.openai.com"],
    silent: true,
    api_key: "test-api-key"
  }

  default_options.merge(options).each do |key, value|
    allow(config).to receive(key).and_return(value)
  end

  allow(Coolhand).to receive(:configuration).and_return(config)
  config
end
