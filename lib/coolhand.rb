# frozen_string_literal: true

require "uri"
require "securerandom"
require "json"
require "base64"
require "time"

require_relative "coolhand/errors"
require_relative "coolhand/version"
require_relative "coolhand/configuration"
require_relative "coolhand/collector"
require_relative "coolhand/declared_context"
require_relative "coolhand/declarable"
require_relative "coolhand/rails_auto_declare"
require_relative "coolhand/log_queue"
require_relative "coolhand/body_redactor"
require_relative "coolhand/string_body_redactor"
require_relative "coolhand/base_interceptor"
require_relative "coolhand/net_http_interceptor"
require_relative "coolhand/batch_body_cap"
require_relative "coolhand/api_service"
require_relative "coolhand/logger_service"
require_relative "coolhand/feedback_service"
require_relative "coolhand/template_service"
require_relative "coolhand/step_template_service"
require_relative "coolhand/optimization_feedback_link_service"
require_relative "coolhand/workload_service"
require_relative "coolhand/help_center_service"
require_relative "coolhand/log_service"
require_relative "coolhand/webhook_interceptor"
# Only when Rails is already loaded; the gem has no Rails dependency.
require_relative "coolhand/railtie" if defined?(Rails::Railtie)

# The main module for the Coolhand gem.
# It provides the configuration interface and initializes the patching.
module Coolhand
  # Class-level instance variables to hold the configuration
  @configuration = Configuration.new

  class << self
    attr_reader :configuration

    # Reset configuration to defaults (mainly for testing)
    def reset_configuration!
      @configuration = Configuration.new
      Thread.current[:coolhand_capture_override] = nil
      DeclaredContext.clear!
    end

    # Provides a block to configure the gem.
    #
    # Example:
    #   Coolhand.configure do |config|
    #     config.environment = 'development'
    #     config.silent = false
    #     config.api_key = "xxx-yyy-zzz"
    #     config.intercept_addresses = ["openai.com", "api.anthropic.com"]
    #   end
    def configure
      yield(configuration)

      return unless configuration.enabled

      configuration.validate!

      NetHttpInterceptor.patch!

      log "✅ Coolhand ready - will log inference calls on monitored URIs"
    end

    def capture
      unless block_given?
        log "❌ Coolhand Error: Method .capture requires block."
        return
      end

      return yield unless configuration.enabled

      NetHttpInterceptor.patch!
      begin
        yield
      ensure
        NetHttpInterceptor.unpatch!
      end
    end

    def without_capture(&block)
      override_capture(false, &block)
    end

    def with_capture(&block)
      override_capture(true, &block)
    end

    # Declares the workload/template that LLM calls captured inside the block belong to. Nested
    # blocks override per field (`reporter`, `workload`, `template`), innermost wins. `workload` and
    # `template` are Hashes with `id:` (an existing record) or `key:` (find-or-created), plus optional
    # `name:` (and `description:` on a workload). See docs/declared_workloads.md.
    #
    # Example:
    #   Coolhand.with_context(reporter: "squishling", workload: { key: "Parser#call" }) { client.chat(...) }
    def with_context(reporter: nil, workload: nil, template: nil, &block)
      raise ArgumentError, "Coolhand.with_context requires a block" unless block

      DeclaredContext.with(reporter: reporter, workload: workload, template: template, &block)
    end

    # Blocks until log requests queued by async logging have been sent, or the timeout (in
    # seconds) elapses. Returns true if everything was sent. Pending logs are also flushed
    # automatically at process exit.
    def flush(timeout: LogQueue::DEFAULT_FLUSH_TIMEOUT)
      LogQueue.flush(timeout)
    end

    # A simple logger that respects the 'silent' configuration option.
    def log(message)
      return if configuration.silent

      puts "COOLHAND: #{message}"
    rescue StandardError
      # Logging must never raise into the host app (e.g. a closed stdout) — least of all from
      # the interceptor's ensure block, where it would replace the host's own response.
      nil
    end

    # Creates a new FeedbackService instance
    def feedback_service
      FeedbackService.new
    end

    # Creates a new LoggerService instance
    def logger_service
      LoggerService.new
    end

    # Creates a new TemplateService instance, for reading LLM request templates back out of
    # Coolhand. Needs the private API key - the public key is write-only on this API.
    def template_service
      TemplateService.new
    end

    # Creates a new StepTemplateService instance, for reading the skills and recurring steps detected
    # in captured agent sessions. Requires the private API key.
    def step_template_service
      StepTemplateService.new
    end

    # Creates a new WorkloadService instance, for listing workloads (with optional cost and
    # performance metrics). Needs the private API key.
    def workload_service
      WorkloadService.new
    end

    # Creates a new LogService instance, for reading logs back out of Coolhand. Distinct from
    # {logger_service}, which writes them. Needs the private API key.
    def log_service
      LogService.new
    end

    # Creates a new HelpCenterService, for reading the Coolhand help center. Needs no API key; a
    # configured one is sent and lifts the anonymous rate limit.
    def help_center_service
      HelpCenterService.new
    end

    # Creates a new OptimizationFeedbackLinkService instance, for linking feedback to an
    # optimization as evidence. Needs the private API key.
    def optimization_feedback_link_service
      OptimizationFeedbackLinkService.new
    end

    def required_field?(value)
      return false if value.nil?
      return false if value.respond_to?(:empty?) && value.empty?
      return false if value.to_s.strip.empty?

      true
    end

    private

    # Forces capture on or off for the block on this thread, restoring the previous override after.
    def override_capture(enabled)
      previous = Thread.current[:coolhand_capture_override]
      Thread.current[:coolhand_capture_override] = enabled
      yield
    ensure
      Thread.current[:coolhand_capture_override] = previous
    end
  end
end
