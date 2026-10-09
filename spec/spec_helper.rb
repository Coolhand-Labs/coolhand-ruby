# frozen_string_literal: true

require "simplecov"
require "coolhand"
require "pry"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Reset configuration before each test to avoid state pollution
  config.before(:each) do
    Coolhand.reset_configuration!
    # Most specs stub ApiService and assert on the call inline; log_queue_spec opts back in.
    Coolhand.configuration.async_logging = false
    Coolhand::NetHttpInterceptor.reset!
  end

  config.after(:each) do
    Coolhand::LogQueue.reset!
  end
end
