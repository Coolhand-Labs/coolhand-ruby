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
    def with(source: nil, workload: nil, template: nil)
      previous = current
      declared = {
        source: normalize_source(source),
        workload: normalize_part(:workload, workload, WORKLOAD_FIELDS),
        template: normalize_part(:template, template, TEMPLATE_FIELDS)
      }.compact
      inherited = previous || {}
      inherited = inherited.except(:template) if declared.key?(:workload) && !declared.key?(:template)
      merged = inherited.merge(declared)
      Thread.current[THREAD_KEY] = merged.empty? ? nil : merged.freeze
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def normalize_source(source)
      return nil if source.nil?

      source.to_s
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
      unless part.key?(:id) || part.key?(:key)
        raise ArgumentError, "#{name} needs an :id or a :key, got #{value.keys.inspect}"
      end

      part.freeze
    end
  end
end
