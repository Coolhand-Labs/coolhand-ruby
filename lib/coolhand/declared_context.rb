# frozen_string_literal: true

module Coolhand
  # Ambient workload/template identity for captured calls, set with {Coolhand.with_context}. The
  # interceptor snapshots {current} on the calling thread before a log is queued, because the
  # background log worker does not inherit thread-locals. See docs/declared_workloads.md.
  module DeclaredContext
    THREAD_KEY = :coolhand_declared_context

    # The fields the server accepts under `declared.workload` / `declared.template`; anything else
    # is dropped here rather than sent.
    WORKLOAD_FIELDS = %i[id key name description].freeze
    TEMPLATE_FIELDS = %i[id key name].freeze

    module_function

    # A frozen Hash, or nil when no context is active.
    def current
      Thread.current[THREAD_KEY]
    end

    def clear!
      Thread.current[THREAD_KEY] = nil
    end

    # Each field is replaced wholesale by the innermost block that sets it. Hashes are not merged
    # key by key: `{ id: x }` merged with `{ key: y }` would declare both, and the server prefers `id`.
    # A template belongs to a workload, so a block that declares a workload without a template does
    # not inherit the outer one; it would pair the new workload with a template from another.
    def with(reporter: nil, workload: nil, template: nil)
      previous = current
      declared = {
        reporter: normalize_reporter(reporter),
        workload: normalize_part(:workload, workload, WORKLOAD_FIELDS),
        template: normalize_part(:template, template, TEMPLATE_FIELDS)
      }.compact
      inherited = previous || {}
      inherited = inherited.except(:template) if declared.key?(:workload) && !declared.key?(:template)
      merged = inherited.merge(declared)
      ensure_template_has_workload!(merged)
      Thread.current[THREAD_KEY] = merged.empty? ? nil : merged.freeze
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def normalize_reporter(reporter)
      return nil if reporter.nil?

      reporter.to_s
    end

    # Mirrors the server's key rules: at most 255 characters, no control or invisible characters, no
    # leading or trailing whitespace, and no leading, trailing or doubled "/". The server answers a
    # bad key with a 422 that rejects the whole log, so it is checked here, before the call is made.
    MAX_KEY_LENGTH = 255
    KEY_FORMAT = %r{
      \A(?!/)(?!.*//)
      [^\p{Cntrl}\p{Cf}[:space:]]
      (?:[^\p{Cntrl}\p{Cf}]*[^\p{Cntrl}\p{Cf}[:space:]])?
      (?<!/)\z
    }x

    def valid_key?(key)
      key.is_a?(String) && key.length <= MAX_KEY_LENGTH && KEY_FORMAT.match?(key)
    end

    # A template given by key, with no workload to create it in, is a 422 that drops the log. A
    # template `id` refers to an existing record and needs no workload.
    def ensure_template_has_workload!(declared)
      template = declared[:template]
      return if template.nil? || template.key?(:id) || declared.key?(:workload)

      raise ArgumentError, "template with a :key needs a workload; declare one in this or an enclosing block"
    end

    # Validated up front: the server answers a non-object `workload`/`template` with a 422 for the
    # whole log, which would drop the call from Coolhand rather than just its identity.
    def normalize_part(name, value, fields)
      return nil if value.nil?
      raise ArgumentError, "#{name} must be a Hash, got #{value.class}" unless value.is_a?(Hash)

      part = value.each_with_object({}) do |(k, v), acc|
        field = k.to_sym
        acc[field] = v.to_s.dup.freeze if fields.include?(field) && !v.nil?
      end
      return nil if part.empty?

      if part.key?(:key) && !valid_key?(part[:key])
        raise ArgumentError, "#{name} key must be at most #{MAX_KEY_LENGTH} printable characters with no " \
                             "surrounding whitespace and no leading, trailing or doubled \"/\""
      end
      unless part.key?(:id) || part.key?(:key)
        raise ArgumentError, "#{name} needs an :id or a :key, got #{value.keys.inspect}"
      end

      part.freeze
    end
  end
end
