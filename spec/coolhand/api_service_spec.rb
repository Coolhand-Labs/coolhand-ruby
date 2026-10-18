# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::ApiService do
  before do
    allow(Coolhand).to receive(:log)
    Coolhand.configure do |c|
      c.api_key = "test-key"
      c.silent = true
    end
  end

  describe "custom base_url" do
    it "uses the configured base_url to build api_endpoint" do
      Coolhand.configuration.base_url = "https://self-hosted.example.com/api"
      service = described_class.new
      expect(service.api_endpoint).to eq("https://self-hosted.example.com/api/v2/llm_request_logs")
    end

    it "strips trailing slash when building api_endpoint" do
      Coolhand.configuration.base_url = "https://self-hosted.example.com/api/"
      service = described_class.new
      expect(service.api_endpoint).to eq("https://self-hosted.example.com/api/v2/llm_request_logs")
    end

    it "sends the HTTP request to the custom host, not the default" do
      Coolhand.configuration.base_url = "https://self-hosted.example.com/api"
      stub_request(:post, "https://self-hosted.example.com/api/v2/llm_request_logs")
        .to_return(status: 200, body: JSON.generate({ id: 99 }), headers: { "Content-Type" => "application/json" })

      described_class.new.send_llm_request_log(
        method: "POST",
        url: "https://api.openai.com/v1/chat/completions",
        request_body: {},
        response_body: {},
        status_code: 200
      )

      expect(WebMock).to have_requested(:post, "https://self-hosted.example.com/api/v2/llm_request_logs")
      expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
    end

    it "does not re-intercept and re-log its own request to the Coolhand API, even when its own host " \
       "matches intercept_addresses" do
      Coolhand.configuration.intercept_addresses = ["coolhandlabs.com"]
      stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
        .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })

      described_class.new.send_llm_request_log(
        method: "POST",
        url: "https://api.openai.com/v1/chat/completions",
        request_body: {},
        response_body: {},
        status_code: 200
      )

      expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs").once
    end
  end

  describe "#send_llm_request_log with missing api_key" do
    let(:service) { described_class.new }
    let(:request_data) do
      { method: "POST", url: "https://api.openai.com/v1/chat/completions",
        request_body: {}, response_body: {}, status_code: 200 }
    end

    before { Coolhand.configuration.api_key = nil }

    it "returns nil without sending an HTTP request" do
      result = service.send_llm_request_log(request_data)
      expect(result).to be_nil
      expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
    end

    it "logs a warning via Coolhand.log (respects silent)" do
      expect(Coolhand).to receive(:log).with(/API key is missing/)
      service.send_llm_request_log(request_data)
    end

    it "produces no output when silent is true" do
      Coolhand.configuration.silent = true
      expect { service.send_llm_request_log(request_data) }.not_to output.to_stdout
    end
  end

  describe "server-supplied response warnings" do
    let(:request_data) do
      { method: "POST", url: "https://api.openai.com/v1/chat/completions",
        request_body: {}, response_body: {}, status_code: 200 }
    end

    before { Coolhand.configuration.silent = false }

    # Returns every stdout line except the success message, so a forged line would show up.
    def warning_lines(warnings)
      stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
        .to_return(status: 200, body: { id: 1, warnings: warnings }.to_json)

      out = StringIO.new
      original = $stdout
      $stdout = out
      begin
        described_class.new.send_llm_request_log(request_data)
      ensure
        $stdout = original
      end
      out.string.lines.map(&:chomp).reject { |line| line.include?("Successfully sent request metadata") }
    end

    it "prints a well-formed warning unchanged" do
      expect(warning_lines(["Declared workload was ignored: over cap"]))
        .to eq(["⚠️ Coolhand: Declared workload was ignored: over cap"])
    end

    it "does not let newlines forge extra log lines" do
      lines = warning_lines(["first\nsecond\r\n✅ Forged: success"])

      expect(lines).to eq(["⚠️ Coolhand: first second ✅ Forged: success"])
    end

    it "strips ANSI escape bytes" do
      lines = warning_lines(["\e[31mred\e[0m \e]0;title\a text"])

      expect(lines.join).not_to match(/[\e\a]/)
      expect(lines.first).to include("red")
    end

    it "replaces C1 and Unicode separators with a space and removes format characters" do
      lines = warning_lines(["a\u0085b\u2028c\u2029d\u202Ee\u200Bf"])

      expect(lines).to eq(["⚠️ Coolhand: a b c def"])
    end

    it "scrubs invalid UTF-8 bytes" do
      text = described_class.new.send(:sanitize_warning, "bad \xFF byte")

      expect(text).to be_valid_encoding
      expect(text).to start_with("bad")
    end

    it "accepts a bare String instead of an Array" do
      expect(warning_lines("just one")).to eq(["⚠️ Coolhand: just one"])
    end

    it "keeps an entry of exactly the maximum length and truncates one character more" do
      limit = Coolhand::ResponseWarnings::MAX_WARNING_LENGTH

      expect(warning_lines(["a" * limit]).first).to eq("⚠️ Coolhand: #{'a' * limit}")
      expect(warning_lines(["a" * (limit + 1)]).first).to end_with("... [truncated]")
    end

    it "truncates an oversized entry" do
      lines = warning_lines(["a" * 10_000])

      expect(lines.size).to eq(1)
      expect(lines.first).to end_with("... [truncated]")
      expect(lines.first.length).to be < 600
    end

    it "coerces non-String entries with to_s" do
      lines = warning_lines([42, { code: "over_cap" }, nil])

      expect(lines.size).to eq(3)
      expect(lines.first).to eq("⚠️ Coolhand: 42")
      expect(lines[1]).to include("over_cap")
    end

    it "prints exactly the maximum number of warnings with no omitted line" do
      lines = warning_lines(Array.new(Coolhand::ResponseWarnings::MAX_WARNINGS) { |i| "w#{i}" })

      expect(lines.size).to eq(Coolhand::ResponseWarnings::MAX_WARNINGS)
      expect(lines.join).not_to include("omitted")
    end

    it "caps how many warnings are printed per response" do
      lines = warning_lines(Array.new(12) { |i| "warning #{i}" })

      expect(lines.size).to eq(Coolhand::ResponseWarnings::MAX_WARNINGS + 1)
      expect(lines.last).to match(/and 7 more warning\(s\) omitted/)
    end
  end

  describe "debug_mode with send_llm_request_log" do
    let(:service) { described_class.new }
    let(:request_data) do
      {
        raw_request: {
          method: "POST",
          url: "https://api.openai.com/v1/chat/completions",
          request_body: { model: "gpt-4" },
          response_body: { choices: [] },
          status_code: 200
        }
      }
    end

    context "when debug_mode is false (default)" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })
      end

      it "sends request to API" do
        service.send_llm_request_log(request_data)
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end
    end

    context "when debug_mode is true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "does not send request to API" do
        result = service.send_llm_request_log(request_data)
        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end

      it "logs payload locally" do
        Coolhand.configuration.silent = false
        expect { service.send_llm_request_log(request_data) }.to output(/Debug Mode/).to_stdout
      end
    end
  end

  describe "debug_mode with create_feedback" do
    let(:service) { Coolhand::FeedbackService.new }
    let(:feedback) do
      {
        llm_request_log_id: 456,
        like: true,
        explanation: "Great response!"
      }
    end

    context "when debug_mode is false" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
          .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })
      end

      it "sends request to API" do
        service.create_feedback(feedback)
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
      end
    end

    context "when debug_mode is true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "does not send request to API" do
        result = service.create_feedback(feedback)
        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_log_feedbacks")
      end
    end
  end

  describe "debug_mode with create_log" do
    let(:service) { Coolhand::LoggerService.new }
    let(:captured_data) do
      {
        method: "POST",
        url: "https://api.openai.com/v1/chat/completions",
        request_body: { model: "gpt-4" },
        response_body: { choices: [] },
        status_code: 200
      }
    end

    context "when debug_mode is false" do
      before do
        stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
          .to_return(status: 200, body: JSON.generate({ id: 1 }), headers: { "Content-Type" => "application/json" })
      end

      it "sends request to API" do
        service.log_to_api(captured_data)
        expect(WebMock).to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end
    end

    context "when debug_mode is true" do
      before do
        Coolhand.configuration.debug_mode = true
      end

      it "does not send request to API" do
        result = service.log_to_api(captured_data)
        expect(result).to be_nil
        expect(WebMock).not_to have_requested(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
      end
    end
  end

  describe "error handling in send_request" do
    let(:service) { described_class.new }
    let(:request_data) do
      { method: "POST", url: "https://api.openai.com/v1/chat/completions",
        request_body: {}, response_body: {}, status_code: 200 }
    end

    before { Coolhand.configuration.silent = false }

    it "truncates HTML error pages instead of dumping the full body" do
      long_html = "<!DOCTYPE html>#{'x' * 500}"
      stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
        .to_return(status: 500, body: long_html)

      expect { service.send_llm_request_log(request_data) }
        .to output(/\[HTML error page truncated\]/).to_stdout
    end

    it "logs the full body for non-HTML error responses" do
      stub_request(:post, "https://coolhandlabs.com/api/v2/llm_request_logs")
        .to_return(status: 500, body: "plain text error")

      expect { service.send_llm_request_log(request_data) }
        .to output(/plain text error/).to_stdout
    end
  end

  describe "#sanitize_payload_for_json" do
    let(:service) do
      instance = described_class.new
      instance.extend(Module.new do
        def sanitize_payload_for_json_public(payload)
          sanitize_payload_for_json(payload)
        end
      end)
      instance
    end

    before { Coolhand.configuration.silent = false }

    it "recovers and logs when sanitizing the payload itself raises" do
      poison_key = Object.new
      def poison_key.to_s
        raise "boom"
      end

      result = nil
      expect { result = service.sanitize_payload_for_json_public({ poison_key => "value" }) }
        .to output(/Warning: Error sanitizing payload/).to_stdout
      expect(result).to eq({ poison_key => "value" })
    end
  end
end
