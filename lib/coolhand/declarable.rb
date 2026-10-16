# frozen_string_literal: true

module Coolhand
  # Declares the workload/template of the LLM calls a class makes, once, on the class, so passive
  # capture picks them up without a `Coolhand.with_context` block at every call site. Wrapped methods
  # run inside `with_context`, so nesting and precedence are exactly those documented in
  # docs/declared_workloads.md. Settings are inherited by subclasses.
  #
  #   class ApplicationService
  #     include Coolhand::Declarable
  #     coolhand_workload reporter: "my-app"
  #     coolhand_declare_all
  #   end
  #
  #   class Parser < ApplicationService
  #     def call = client.chat(...) # workload "Parser#call", template "Parser#call"
  #   end
  module Declarable
    def self.included(base)
      raise ArgumentError, "Coolhand::Declarable can only be included in a class" unless base.is_a?(Class)

      base.extend(ClassMethods)
    end

    # Never an LLM call site, and wrapping them would tax every call or declare a junk workload.
    SKIPPED_METHODS = %i[method_missing respond_to? respond_to_missing? == === eql? equal? hash to_s inspect
                         to_str to_ary to_proc coerce <=>].freeze
    ATTRIBUTE_MACROS = %w[attr attr_reader attr_writer attr_accessor].freeze
    private_constant :SKIPPED_METHODS, :ATTRIBUTE_MACROS

    module ClassMethods
      # Class-level defaults, inherited field by field (the nearest class that sets a field wins). With
      # no `key`, each wrapped method declares its own workload, "ClassName#method"; a `key` makes every
      # method share one workload. The class name is the runtime class, so an inherited method declares
      # under the subclass.
      def coolhand_workload(key: nil, name: nil, description: nil, reporter: nil)
        workload = DeclaredContext.normalize_part(:workload, { key: key, name: name, description: description }.compact,
          DeclaredContext::WORKLOAD_FIELDS)
        @coolhand_settings = { workload: workload, reporter: DeclaredContext.normalize_reporter(reporter) }.compact
      end

      # Wraps the named instance methods (now, or when they are defined later). `template:` is a key or a
      # `{ key:, name: }` Hash; by default the template key is "ClassName#method".
      def coolhand_declare(*names, template: nil)
        # Checked here, at class definition, so a bad value never surfaces inside the host's method.
        template = DeclaredContext.normalize_part(:template, template.is_a?(String) ? { key: template } : template,
          DeclaredContext::TEMPLATE_FIELDS)
        names.flatten.each do |name|
          name = name.to_sym
          (@coolhand_declared ||= {})[name] = { template: template }
          coolhand_wrap(name) if method_defined?(name) || private_method_defined?(name)
        end
      end

      # Wraps every public instance method defined in this class and its subclasses after this call, so
      # put it at the top of the class body. Private and protected methods, attribute readers/writers
      # and object-protocol methods (see SKIPPED_METHODS) are left alone; `coolhand_declare` wraps one of
      # those if you name it.
      def coolhand_declare_all
        @coolhand_declare_all = true
      end

      # @api private
      def coolhand_identity(method_name)
        key = "#{name}##{method_name}"
        template = coolhand_template_for(method_name)
        {
          reporter: coolhand_setting(:reporter),
          workload: { key: key }.merge(coolhand_setting(:workload) || {}),
          template: template || { key: key }
        }
      end

      # @api private
      def coolhand_declare_call?(method_name)
        return false if name.nil? || !Coolhand.configuration.enabled
        return false unless DeclaredContext.valid_key?("#{name}##{method_name}")

        public_method_defined?(method_name) || !coolhand_declaration(method_name).nil?
      end

      # @api private
      def coolhand_own_state
        [@coolhand_settings, @coolhand_declared, @coolhand_declare_all]
      end

      private

      def method_added(method_name)
        super
        coolhand_wrap(method_name) if !@coolhand_wrapping && coolhand_wrap?(method_name)
      end

      def coolhand_wrap?(method_name)
        return true if coolhand_declaration(method_name)

        public_method_defined?(method_name) && !SKIPPED_METHODS.include?(method_name) &&
          !attribute_definition? && coolhand_declare_all?
      end

      # True while `attr_reader`/`attr_writer`/`attr_accessor` is what is defining the method. Read from
      # the stack rather than by overriding those macros, which would lose the class body's
      # `private`/`protected` default visibility. A window of frames, not one fixed depth, so a
      # `method_added` override that calls `super` does not hide the macro.
      def attribute_definition?
        caller_locations(1, 8)&.any? { |frame| ATTRIBUTE_MACROS.include?(frame.base_label) } || false
      end

      def coolhand_declare_all?
        coolhand_each_class { |klass| return true if klass.coolhand_own_state[2] }
        false
      end

      # Redefines the method in the same class, rather than prepending a wrapper, so a later
      # `private :name` (or `private def name`) applies to the wrapper like it would to the original.
      def coolhand_wrap(method_name)
        original = instance_method(method_name)
        wrappers = (@coolhand_wrappers ||= {})
        return if wrappers[method_name] == original

        visibility = coolhand_visibility(method_name)
        @coolhand_wrapping = true
        define_method(method_name) do |*args, **kwargs, &block|
          klass = self.class
          next original.bind_call(self, *args, **kwargs, &block) unless klass.coolhand_declare_call?(method_name)

          Coolhand.with_context(**klass.coolhand_identity(method_name)) do
            original.bind_call(self, *args, **kwargs, &block)
          end
        end
        send(visibility, method_name)
        wrappers[method_name] = instance_method(method_name)
      ensure
        @coolhand_wrapping = false
      end

      # Includes inherited methods: wrapping one a parent made private must not make it public here.
      def coolhand_visibility(method_name)
        return :private if private_method_defined?(method_name)
        return :protected if protected_method_defined?(method_name)

        :public
      end

      # Yields this class and its superclasses that include Declarable, nearest first. A loop rather
      # than a collected Array, since the lookups below run on every wrapped call.
      def coolhand_each_class
        klass = self
        while klass.respond_to?(:coolhand_own_state)
          yield klass
          klass = klass.superclass
        end
      end

      def coolhand_declaration(method_name)
        coolhand_each_class do |klass|
          declared = klass.coolhand_own_state[1]
          return declared[method_name] if declared&.key?(method_name)
        end
        nil
      end

      def coolhand_template_for(method_name)
        coolhand_declaration(method_name)&.fetch(:template)
      end

      def coolhand_setting(field)
        coolhand_each_class do |klass|
          settings = klass.coolhand_own_state[0]
          return settings[field] if settings&.key?(field)
        end
        nil
      end
    end
  end
end
