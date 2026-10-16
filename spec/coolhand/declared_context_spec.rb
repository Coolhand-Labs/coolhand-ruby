# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "net/http"

RSpec.describe Coolhand::DeclaredContext do
  describe ".with_context" do
    it "requires a block" do
      expect { Coolhand.with_context(source: "x") }.to raise_error(ArgumentError, /requires a block/)
    end

    it "is nil outside any block" do
      expect(described_class.current).to be_nil
    end

    it "exposes a frozen snapshot of the declared identity inside the block" do
      Coolhand.with_context(source: "squishling", workload: { key: "Parser#call", name: "Parser#call" },
        template: { "key" => "Parser#call/squish:L2" }) do
        expect(described_class.current).to eq(
          source: "squishling",
          workload: { key: "Parser#call", name: "Parser#call" },
          template: { key: "Parser#call/squish:L2" }
        )
        expect(described_class.current).to be_frozen
        expect(described_class.current[:workload]).to be_frozen
      end
    end

    it "drops fields the server does not accept and nil values" do
      Coolhand.with_context(workload: { key: "w", bogus: "x", description: nil }, template: { description: "no" }) do
        expect(described_class.current).to eq(workload: { key: "w" })
      end
    end

    it "does not let later mutation of the caller's hash change the snapshot" do
      workload = { key: "w" }
      Coolhand.with_context(workload: workload) do
        workload[:key] = "changed"
        expect(described_class.current[:workload]).to eq(key: "w")
      end
    end

    it "leaves no context when nothing is declared" do
      Coolhand.with_context { expect(described_class.current).to be_nil }
    end

    it "merges nested blocks per field, innermost winning" do
      Coolhand.with_context(source: "outer", workload: { key: "w" }) do
        Coolhand.with_context(template: { key: "t" }) do
          expect(described_class.current).to eq(source: "outer", workload: { key: "w" }, template: { key: "t" })
        end
        Coolhand.with_context(source: "inner") do
          expect(described_class.current[:source]).to eq("inner")
        end
        expect(described_class.current).to eq(source: "outer", workload: { key: "w" })
      end
    end

    it "replaces a workload wholesale instead of merging its keys" do
      Coolhand.with_context(workload: { id: "abc", key: "outer" }) do
        Coolhand.with_context(workload: { key: "inner" }) do
          expect(described_class.current[:workload]).to eq(key: "inner")
        end
      end
    end

    it "drops the inherited template when an inner block declares a different workload" do
      Coolhand.with_context(source: "outer", workload: { key: "a" }, template: { key: "a/t" }) do
        Coolhand.with_context(workload: { key: "b" }) do
          expect(described_class.current).to eq(source: "outer", workload: { key: "b" })
        end
        Coolhand.with_context(workload: { key: "b" }, template: { key: "b/t" }) do
          expect(described_class.current[:template]).to eq(key: "b/t")
        end
        expect(described_class.current[:template]).to eq(key: "a/t")
      end
    end

    it "restores the previous context after the block, even when it raises" do
      expect do
        Coolhand.with_context(source: "x") { raise "boom" }
      end.to raise_error("boom")
      expect(described_class.current).to be_nil
    end

    it "returns the block's value" do
      expect(Coolhand.with_context(source: "x") { :result }).to eq(:result)
    end

    it "rejects a non-Hash workload or template before running the block" do
      ran = false
      expect { Coolhand.with_context(workload: "Parser#call") { ran = true } }
        .to raise_error(ArgumentError, /workload must be a Hash/)
      expect { Coolhand.with_context(template: ["t"]) { ran = true } }
        .to raise_error(ArgumentError, /template must be a Hash/)
      expect(ran).to be false
      expect(described_class.current).to be_nil
    end

    it "rejects a workload or template with neither id nor key" do
      expect do
        Coolhand.with_context(workload: { name: "n" }) do
          nil
        end
      end.to raise_error(ArgumentError, /needs an :id or a :key/)
      expect do
        Coolhand.with_context(template: { name: "n" }) do
          nil
        end
      end.to raise_error(ArgumentError, /needs an :id or a :key/)
    end

    it "does not leak into other threads" do
      seen = :unset
      Coolhand.with_context(source: "x") { Thread.new { seen = described_class.current }.join }
      expect(seen).to be_nil
    end

    it "is cleared by reset_configuration!" do
      Thread.current[described_class::THREAD_KEY] = { source: "x" }
      Coolhand.reset_configuration!
      expect(described_class.current).to be_nil
    end
  end

  describe "captured Net::HTTP calls" do
    let(:coolhand_url) { "https://coolhandlabs.com/api/v2/llm_request_logs" }
    let(:posted) { [] }

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

    def call_llm
      uri = URI("https://api.test.com/hello")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.request(Net::HTTP::Get.new(uri))
    end

    it "sends declared next to raw_request and collector" do
      Coolhand.with_context(source: "squishling", workload: { key: "Parser#call" }, template: { key: "t1" }) do
        call_llm
      end

      log = posted.fetch(0).fetch("llm_request_log")
      expect(log).to include("raw_request", "collector")
      expect(log["declared"]).to eq(
        "source" => "squishling",
        "workload" => { "key" => "Parser#call" },
        "template" => { "key" => "t1" }
      )
    end

    it "omits declared outside a context" do
      call_llm

      expect(posted.fetch(0).fetch("llm_request_log")).not_to have_key("declared")
    end

    it "keeps the snapshot when logs are sent from the background queue" do
      Coolhand.configuration.async_logging = true

      Coolhand.with_context(workload: { key: "Parser#call" }) { call_llm }
      Coolhand.with_context(workload: { key: "Other#call" }) { call_llm }
      expect(Coolhand.flush(timeout: 2)).to be true

      expect(posted.map { |p| p.dig("llm_request_log", "declared", "workload", "key") })
        .to contain_exactly("Parser#call", "Other#call")
    end

    it "logs warnings the server returns for an ignored declaration" do
      Coolhand.configuration.silent = false
      stub_request(:post, coolhand_url).to_return(
        status: 200, body: { warnings: ["Declared workload/template was ignored: over cap"] }.to_json
      )

      expect { Coolhand.with_context(workload: { key: "w" }) { call_llm } }
        .to output(%r{Declared workload/template was ignored: over cap}).to_stdout
    end
  end
end
