# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"

RSpec.describe Coolhand::Declarable do
  let(:seen) { [] }

  # Records the context in effect when the method body runs.
  def self.recorder
    Module.new do
      def record(seen)
        seen << Coolhand::DeclaredContext.current
        :done
      end
    end
  end

  def define_class(superclass = Object, name: "Anon#{SecureRandom.hex(3)}", &block)
    klass = Class.new(superclass, &block)
    stub_const(name, klass)
    klass
  end

  it "can only be included in a class" do
    expect { Module.new { include Coolhand::Declarable } }.to raise_error(ArgumentError, /only be included in a class/)
  end

  describe ".coolhand_declare" do
    it "wraps the named methods, declaring workload and template as Class#method" do
      klass = define_class(name: "Parser") do
        include Coolhand::Declarable

        coolhand_declare :call

        def call(seen) = (seen << Coolhand::DeclaredContext.current)
        def other(seen) = (seen << Coolhand::DeclaredContext.current)
      end

      klass.new.call(seen)
      klass.new.other(seen)

      expect(seen).to eq([{ workload: { key: "Parser#call" }, template: { key: "Parser#call" } }, nil])
    end

    it "wraps a method defined after the declaration" do
      klass = define_class(name: "Late") do
        include Coolhand::Declarable

        coolhand_declare :run

        def run(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key))
      end

      klass.new.run(seen)
      expect(seen).to eq(["Late#run"])
    end

    it "uses an explicit template key or Hash" do
      klass = define_class(name: "Tpl") do
        include Coolhand::Declarable

        coolhand_declare :a, template: "Tpl/summarise"
        coolhand_declare :b, template: { key: "Tpl/b", name: "B" }

        def a(seen) = (seen << Coolhand::DeclaredContext.current[:template])
        def b(seen) = (seen << Coolhand::DeclaredContext.current[:template])
      end

      klass.new.a(seen)
      klass.new.b(seen)
      expect(seen).to eq([{ key: "Tpl/summarise" }, { key: "Tpl/b", name: "B" }])
    end

    it "passes arguments, keywords, blocks and the return value through" do
      klass = define_class(name: "Args") do
        include Coolhand::Declarable

        coolhand_declare :call

        def call(a, b = 2, *rest, key: 1, **opts, &block) = [a, b, rest, key, opts, block&.call]
      end

      expect(klass.new.call(1, 3, 4, key: 5, z: 6) { :blk }).to eq([1, 3, [4], 5, { z: 6 }, :blk])
      expect(klass.new.call({ h: 1 })).to eq([{ h: 1 }, 2, [], 1, {}, nil])
    end

    it "rejects an invalid template when declared, not when the method runs" do
      klass = define_class(name: "BadTpl") { include Coolhand::Declarable }

      expect { klass.coolhand_declare(:go, template: 5) }
        .to raise_error(ArgumentError, /template must be a Hash/)
    end

    it "restores the context after the method, even when it raises" do
      klass = define_class(name: "Boom") do
        include Coolhand::Declarable

        coolhand_declare :call

        def call = raise("boom")
      end

      expect { klass.new.call }.to raise_error("boom")
      expect(Coolhand::DeclaredContext.current).to be_nil
    end
  end

  describe ".coolhand_workload" do
    it "shares one workload across methods when a key is given, and adds reporter and name" do
      klass = define_class(name: "Svc") do
        include Coolhand::Declarable

        coolhand_workload key: "Svc", name: "Service", description: "d", reporter: "my-app"
        coolhand_declare_all

        def call(seen) = (seen << Coolhand::DeclaredContext.current)
      end

      klass.new.call(seen)
      expect(seen).to eq([{ reporter: "my-app", workload: { key: "Svc", name: "Service", description: "d" },
                            template: { key: "Svc#call" } }])
    end

    it "is inherited field by field, with the nearest class winning" do
      base = define_class(name: "Base") do
        include Coolhand::Declarable

        coolhand_workload key: "Shared", reporter: "base"
        coolhand_declare_all
      end
      child = define_class(base, name: "Child") do
        coolhand_workload reporter: "child"

        def call(seen) = (seen << Coolhand::DeclaredContext.current)
      end

      child.new.call(seen)
      expect(seen.first).to include(reporter: "child", workload: { key: "Shared" }, template: { key: "Child#call" })
    end
  end

  describe ".coolhand_declare_all" do
    let(:base) do
      define_class(name: "AppService") do
        include Coolhand::Declarable

        coolhand_declare_all
      end
    end

    it "wraps public methods of subclasses by runtime class, including inherited ones" do
      base.class_eval { def call(seen) = (seen << Coolhand::DeclaredContext.current[:workload][:key]) }
      parser = define_class(base, name: "Parser")
      summariser = define_class(base, name: "Summariser") do
        def call(seen)
          super
          seen << :sub
        end
      end

      parser.new.call(seen)
      summariser.new.call(seen)

      expect(seen).to eq(["Parser#call", "Summariser#call", :sub])
    end

    it "only wraps methods defined after declare_all is called" do
      klass = define_class(name: "Existing") do
        include Coolhand::Declarable

        def before(seen) = (seen << Coolhand::DeclaredContext.current)
        coolhand_declare_all

        def after(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key))
      end

      klass.new.before(seen)
      klass.new.after(seen)
      expect(seen).to eq([nil, "Existing#after"])
    end

    it "skips object-protocol methods but wraps them when named" do
      klass = define_class(base, name: "Proto") do
        coolhand_declare :to_s

        def to_s = Coolhand::DeclaredContext.current&.dig(:workload, :key).to_s
        def inspect = Coolhand::DeclaredContext.current.inspect
        def method_missing(*) = Coolhand::DeclaredContext.current.inspect
        def respond_to_missing?(*) = true
      end

      expect(klass.new.to_s).to eq("Proto#to_s")
      expect(klass.new.inspect).to eq("nil")
      expect(klass.new.anything).to eq("nil")
    end

    it "leaves private and protected methods alone, however they are made private" do
      klass = define_class(base, name: "Visible") do
        def pub(seen) = helper(seen) + inline(seen) + prot(seen)

        private def helper(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key)).size
        def inline(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key)).size
        private :inline

        protected

        def prot(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key)).size
      end

      klass.new.pub(seen)

      expect(seen).to all(eq("Visible#pub"))
      expect { klass.new.helper(seen) }.to raise_error(NoMethodError, /private method/)
      expect { klass.new.inline(seen) }.to raise_error(NoMethodError, /private method/)
      expect { klass.new.prot(seen) }.to raise_error(NoMethodError, /protected method/)
    end

    it "declares a method that is explicitly named even when it is private" do
      klass = define_class(base, name: "Explicit") do
        coolhand_declare :secret

        def secret(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key))
        private :secret

        public

        def pub(seen) = secret(seen)
      end

      klass.new.pub(seen)
      expect(seen).to eq(["Explicit#secret"]) # named explicitly, so it declares itself even though private
    end

    it "keeps an inherited private method private when it is declared in a subclass" do
      parent = define_class(name: "Parent") do
        include Coolhand::Declarable

        private def secret(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key))
      end
      child = define_class(parent, name: "Child") { coolhand_declare :secret }

      expect(child.private_method_defined?(:secret)).to be true
      expect { child.new.secret(seen) }.to raise_error(NoMethodError, /private method/)
      expect(child.new.respond_to?(:secret)).to be false
    end

    it "keeps private and protected attribute macros private in a Declarable class" do
      klass = define_class(base, name: "Hidden") do
        private

        attr_reader :hidden
        attr_accessor :hidden2

        protected

        attr_reader :guarded

        public

        attr_reader :shown
      end

      expect(klass.private_instance_methods(false)).to include(:hidden, :hidden2, :hidden2=)
      expect(klass.protected_instance_methods(false)).to include(:guarded)
      expect(klass.public_instance_methods(false)).to contain_exactly(:shown)
    end

    it "still skips attribute macros when a method_added override calls super" do
      klass = define_class(base, name: "Hooked") do
        def self.method_added(name)
          (@added ||= []) << name
          super
        end

        attr_accessor :value

        def call(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key))
      end
      probe = klass.new
      probe.value = 1
      probe.call(seen)

      expect(klass.instance_variable_get(:@coolhand_wrappers).keys).to eq([:call])
      expect(seen).to eq(["Hooked#call"])
    end

    it "does not expose its constants on including classes" do
      klass = define_class(base, name: "Clean")

      expect(klass.constants).not_to include(:SKIPPED_METHODS, :ATTRIBUTE_MACROS)
    end

    it "does not wrap attribute readers and writers" do
      klass = define_class(base, name: "Attrs") do
        attr_accessor :value

        def call(seen) = (seen << Coolhand::DeclaredContext.current&.dig(:workload, :key))
      end
      probe = klass.new
      probe.value = 1

      expect(probe.value).to eq(1)
      Coolhand.with_context(workload: { key: "Outer" }) do
        probe.value
        probe.call(seen)
      end
      expect(seen).to eq(["Attrs#call"])
    end

    it "skips declaring, rather than raising, when the computed key is too long" do
      klass = define_class(base, name: "L#{'o' * 260}ng") { def call(seen) = (seen << Coolhand::DeclaredContext.current) }

      klass.new.call(seen)
      expect(seen).to eq([nil])
    end

    it "skips anonymous classes" do
      klass = Class.new(base) { def call(seen) = (seen << Coolhand::DeclaredContext.current) }

      klass.new.call(seen)
      expect(seen).to eq([nil])
    end

    it "skips declaring when Coolhand is disabled" do
      klass = define_class(base, name: "Off") { def call(seen) = (seen << Coolhand::DeclaredContext.current) }
      Coolhand.configuration.enabled = false

      klass.new.call(seen)
      expect(seen).to eq([nil])
    end

    it "lets an explicit with_context inside a wrapped method override the class declaration" do
      klass = define_class(base, name: "Override") do
        def call(seen)
          Coolhand.with_context(workload: { key: "Custom" }, template: { key: "Custom/t" }) do
            seen << Coolhand::DeclaredContext.current
          end
        end
      end

      klass.new.call(seen)
      expect(seen.first).to include(workload: { key: "Custom" }, template: { key: "Custom/t" })
    end

    it "does not carry a calling service's template into a nested service's workload" do
      inner = define_class(base, name: "Inner") do
        def call(seen) = (seen << Coolhand::DeclaredContext.current)
      end
      outer = define_class(base, name: "Outer") do
        define_method(:call) { |seen, inner| inner.new.call(seen) }
      end

      outer.new.call(seen, inner)
      expect(seen.first).to include(workload: { key: "Inner#call" }, template: { key: "Inner#call" })
    end
  end

  describe "captured Net::HTTP calls" do
    let(:coolhand_url) { "https://coolhandlabs.com/api/v2/llm_request_logs" }
    let(:posted) { [] }
    let(:service) do
      define_class(name: "Summariser") do
        include Coolhand::Declarable

        coolhand_workload reporter: "my-app"
        coolhand_declare_all

        def call
          uri = URI("https://api.test.com/hello")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.request(Net::HTTP::Get.new(uri))
        end
      end
    end

    before do
      Coolhand.configure do |c|
        c.api_key = "test-key"
        c.silent = true
        c.intercept_addresses = ["api.test.com"]
      end
      stub_request(:get, "https://api.test.com/hello").to_return(status: 200, body: '{"msg":"hi"}')
      stub_request(:post, coolhand_url).to_return do |request|
        posted << JSON.parse(request.body)
        { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }
      end
    end

    it "sends the declaration made on the class, inline and from the background queue" do
      service.new.call
      Coolhand.configuration.async_logging = true
      service.new.call
      expect(Coolhand.flush(timeout: 2)).to be true

      expect(posted.map { |p| p.dig("llm_request_log", "declared") }).to all(eq(
        "reporter" => "my-app",
        "workload" => { "key" => "Summariser#call" },
        "template" => { "key" => "Summariser#call" }
      ))
      expect(posted.size).to eq(2)
    end
  end
end
