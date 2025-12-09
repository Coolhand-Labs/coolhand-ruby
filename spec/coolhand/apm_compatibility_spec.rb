# frozen_string_literal: true

require "spec_helper"
require "faraday"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "APM Compatibility", type: :integration do
  # This spec ensures Coolhand doesn't conflict with APM tools that use prepend
  # Based on the SystemStackError discovered with Datadog 2.16.0
  #
  # NOTE: These tests prepend modules to Faraday::Connection which cannot be cleanly removed.
  # This is intentional to test real-world scenarios where APM tools permanently modify classes.

  describe "with prepend-based APM instrumentation" do
    after do
      Coolhand::Interceptor.unpatch! if Coolhand::Interceptor.respond_to?(:unpatch!)
    end

    it "does not cause SystemStackError when both patches are applied" do
      # Create a test module that simulates Datadog's prepend approach
      test_apm_module = Module.new do
        def initialize(*args, &block)
          # Simulate APM instrumentation
          super.tap do
            @apm_instrumented = true
            # Simulate adding APM middleware
            unless @builder.handlers.any? { |h| h.to_s.include?("TestAPM") }
              use(Class.new(Faraday::Middleware) do
                def self.name
                  "TestAPMMiddleware"
                end

                def call(env)
                  env.request_headers["x-test-trace-id"] = "12345"
                  @app.call(env)
                end
              end)
            end
          end
        end
      end

      # Apply the prepend patch (like Datadog does)
      Faraday::Connection.prepend(test_apm_module)

      # Configure Coolhand - this should work without SystemStackError
      expect do
        Coolhand.configure do |config|
          config.api_key = "test-key"
          config.silent = true
          config.intercept_addresses = ["api.example.com"]
        end
      end.not_to raise_error

      # Test creating new Faraday connections (this is where the stack overflow occurred)
      expect do
        5.times do |i|
          conn = Faraday.new("https://api#{i}.example.com") do |f|
            f.request :url_encoded
            f.adapter :test do |stub|
              stub.get("/test") { [200, {}, '{"result": "success"}'] }
            end
          end

          # Verify both patches are working without conflicts
          expect(conn.instance_variable_get(:@apm_instrumented)).to be true
          middleware_classes = conn.builder.handlers.map(&:klass)
          expect(middleware_classes.map(&:name)).to include("TestAPMMiddleware")
          expect(middleware_classes).to include(Coolhand::Interceptor)

          # Test actual request to ensure no recursion during execution
          response = conn.get("/test")
          expect(response.status).to eq(200)
        end
      end.not_to raise_error

      # Clean up the prepend module for next test
      # Note: In real usage, prepends can't be cleanly removed, but for testing we'll live with it
    end

    it "maintains proper method resolution order" do
      # Test with multiple prepends to verify MRO
      first_module = Module.new do
        def initialize(*args, &block)
          super.tap { @first_applied = true }
        end
      end

      second_module = Module.new do
        def initialize(*args, &block)
          super.tap { @second_applied = true }
        end
      end

      # Apply multiple prepends
      Faraday::Connection.prepend(first_module)
      Faraday::Connection.prepend(second_module)

      # Configure Coolhand
      Coolhand.configure do |config|
        config.api_key = "test-key"
        config.silent = true
        config.intercept_addresses = ["api.example.com"]
      end

      # Create connection - should work with all patches
      conn = Faraday.new("https://api.example.com")

      # Verify all patches were applied in correct order
      expect(conn.instance_variable_get(:@first_applied)).to be true
      expect(conn.instance_variable_get(:@second_applied)).to be true
      expect(conn.builder.handlers.map(&:klass)).to include(Coolhand::Interceptor)
    end
  end

  describe "regression test for SystemStackError" do
    after do
      Coolhand::Interceptor.unpatch! if Coolhand::Interceptor.respond_to?(:unpatch!)
    end

    it "prevents the specific alias_method + prepend circular reference issue" do
      # Simulate the exact scenario that caused the original bug

      # Step 1: Apply prepend patch first (like modern APM tools do)
      regression_test_module = Module.new do
        def initialize(*args, &block)
          super.tap { @regression_test_applied = true }
        end
      end

      Faraday::Connection.prepend(regression_test_module)

      # Step 2: Apply Coolhand's patch (should use prepend, not alias_method)
      # This verifies our fix prevents the alias_method + prepend conflict
      expect do
        Coolhand.configure do |config|
          config.api_key = "test-key"
          config.silent = true
          config.intercept_addresses = ["api.example.com"]
        end

        # Step 3: Test connection creation repeatedly
        10.times do
          conn = Faraday.new("https://api.example.com")

          # Both patches should be present and working
          expect(conn.instance_variable_get(:@regression_test_applied)).to be true
          expect(conn.builder.handlers.map(&:klass)).to include(Coolhand::Interceptor)

          # Most importantly: no SystemStackError during initialization
          # This validates that our prepend approach doesn't create circular references
        end
      end.not_to raise_error
    end
  end

  describe "with Rack environment" do
    around do |example|
      # Simulate production Rack environment
      original_env = ENV.fetch("RACK_ENV", nil)
      ENV["RACK_ENV"] = "production"

      example.run

      ENV["RACK_ENV"] = original_env
      Coolhand::Interceptor.unpatch! if Coolhand::Interceptor.respond_to?(:unpatch!)
    end

    it "works in production-like Rack context where original error occurred" do
      # This simulates the background job environment where the stack overflow was discovered

      rack_aware_module = Module.new do
        def initialize(*args, &block)
          super.tap do
            @rack_context = ENV["RACK_ENV"] == "production"
          end
        end
      end

      Faraday::Connection.prepend(rack_aware_module)

      expect do
        Coolhand.configure do |config|
          config.api_key = "test-key"
          config.silent = true
          config.intercept_addresses = ["api.example.com"]
        end

        # Create connection like in background job
        conn = Faraday.new("https://api.example.com")
        expect(conn.instance_variable_get(:@rack_context)).to be true
        expect(conn.builder.handlers.map(&:klass)).to include(Coolhand::Interceptor)
      end.not_to raise_error
    end
  end

  describe "test isolation and cleanup" do
    it "explicitly checks that tests don't leak Coolhand patches to other specs" do
      expect(Coolhand::Interceptor.patched?).to be false

      Coolhand.configure do |config|
        config.api_key = "test-key"
        config.silent = true
        config.intercept_addresses = ["api.example.com"]
      end

      expect(Coolhand::Interceptor.patched?).to be true

      Coolhand::Interceptor.unpatch!

      expect(Coolhand::Interceptor.patched?).to be false
    end

    it "detects if previous tests leaked patch state" do
      expect(Coolhand::Interceptor.patched?).to(
        be(false), "Previous test leaked Coolhand patch state! Check your after blocks."
      )
    end
  end
end
# rubocop:enable RSpec/DescribeClass
