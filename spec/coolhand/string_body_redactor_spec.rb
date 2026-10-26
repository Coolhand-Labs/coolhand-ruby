# frozen_string_literal: true

require "spec_helper"

RSpec.describe Coolhand::StringBodyRedactor do
  def data_payloads(stream)
    stream.lines.grep(/\Adata: ?[{\[]/).grep_v(/\[DONE\]/).map { |line| JSON.parse(line.sub(/\Adata: ?/, "")) }
  end

  # An OpenAI Chat Completions stream whose mcp tool call echoes a credential-named field.
  let(:openai_stream) do
    [
      %(data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"}}]}),
      %(data: {"id":"chatcmpl-1","tools":[{"type":"mcp","server_url":"https://m/s","authorization":"Bearer sk-L1"}]}),
      %(data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hi"}}],"usage":{"total_tokens":12}}),
      "data: [DONE]",
      ""
    ].join("\n\n")
  end

  # An Anthropic Messages stream: `event:` lines, JSON data lines and a ping.
  let(:anthropic_stream) do
    <<~SSE
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1","mcp_servers":[{"name":"x","authorization_token":"tok-LIVE-2"}]}}

      event: ping
      data: {"type":"ping"}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"password: hunter2"}}

    SSE
  end

  describe ".redact" do
    it "redacts credential-named fields inside the data lines of an OpenAI stream" do
      result = described_class.redact(openai_stream)

      expect(result).not_to include("sk-L1")
      expect(data_payloads(result)[1]["tools"][0]).to include("authorization" => "[REDACTED]", "type" => "mcp")
    end

    it "leaves untouched lines, [DONE] and the framing byte for byte" do
      result = described_class.redact(openai_stream)
      original = openai_stream.lines
      redacted = result.lines

      expect(redacted.size).to eq(original.size)
      redacted.zip(original).each_with_index do |(new_line, old_line), i|
        expect(new_line).to eq(old_line) unless i == 2
      end
      expect(result).to end_with("data: [DONE]\n\n")
    end

    it "redacts an Anthropic stream and keeps event: lines and model text as is" do
      result = described_class.redact(anthropic_stream)

      expect(result).not_to include("tok-LIVE-2")
      expect(result).to include("event: message_start\n", "event: ping\ndata: {\"type\":\"ping\"}\n")
      expect(result).to include("password: hunter2")
      expect(data_payloads(result).first.dig("message", "mcp_servers", 0, "authorization_token")).to eq("[REDACTED]")
    end

    it "returns the very same String when nothing needed redacting" do
      clean = "event: ping\ndata: {\"type\":\"ping\"}\n\ndata: [DONE]\n\n"

      expect(described_class.redact(clean)).to equal(clean)
    end

    it "does not mutate its input" do
      input = openai_stream.dup.freeze

      expect { described_class.redact(input) }.not_to raise_error
      expect(input).to eq(openai_stream)
    end

    it "handles CRLF and bare CR line endings and keeps them" do
      crlf = %(data: {"api_key":"sk-1"}\r\n\r\ndata: {"a":1}\r\n\r\n)
      cr = %(data: {"api_key":"sk-1"}\rdata: {"a":1}\r)

      expect(described_class.redact(crlf)).to eq(%(data: {"api_key":"[REDACTED]"}\r\n\r\ndata: {"a":1}\r\n\r\n))
      expect(described_class.redact(cr)).to eq(%(data: {"api_key":"[REDACTED]"}\rdata: {"a":1}\r))
    end

    it "keeps whatever whitespace follows the colon" do
      expect(described_class.redact(%(data:{"password":"p"}\n))).to eq(%(data:{"password":"[REDACTED]"}\n))
      expect(described_class.redact(%(data:\t {"password":"p"}\n))).to eq(%(data:\t {"password":"[REDACTED]"}\n))
    end

    it "normalizes JSON values on re-serialization: big integers and unicode survive, floats go to double precision" do
      big = 123_456_789_012_345_678_901_234_567_890
      result = described_class.redact(%(data: {"password":"p","id":#{big},"t":"caf\\u00e9","f":1.10}))

      expect(result).to eq(%(data: {"password":"[REDACTED]","id":#{big},"t":"café","f":1.1}))
    end

    it "leaves malformed and non-JSON data lines alone and still redacts the good ones" do
      stream = [
        'data: {"api_key": "sk-1", broken',
        "data: plain text api_key=abc",
        'data: "api_key"',
        "data: 42",
        "data:",
        "data: []",
        ": comment {\"api_key\":\"sk-2\"}",
        "retry: 100",
        "  data: {\"api_key\":\"sk-3\"}",
        'data: {"api_key":"sk-4"}'
      ].join("\n")

      result = described_class.redact(stream)

      expect(result.lines[0..8].join).to eq(stream.lines[0..8].join)
      expect(result.lines.last).to eq(%(data: {"api_key":"[REDACTED]"}))
    end

    it "does not treat data: in the middle of a line as a field" do
      line = %(event: x data: {"api_key":"sk-1"}\n)

      expect(described_class.redact(line)).to equal(line)
    end

    it "replaces a data payload nested deeper than the depth guard with a marker" do
      deep = ("[" * 150) + ("]" * 150)
      result = described_class.redact("data: #{deep}\ndata: {\"ok\":true}\n")

      expect(result.lines.first).to eq(%(data: {"_coolhand_capture_skipped":"nesting_too_deep"}\n))
      expect(result.lines.last).to eq(%(data: {"ok":true}\n))
    end

    it "scrubs invalid UTF-8 rather than failing, and still redacts" do
      stream = "data: {\"api_key\":\"sk-1\",\"t\":\"\xFF\"}\n".b

      result = described_class.redact(stream)

      expect(result).to be_valid_encoding
      expect(result).not_to include("sk-1")
    end

    it "returns binary-tagged clean input unchanged" do
      body = "plain \xFF bytes".b

      expect(described_class.redact(body)).to equal(body)
    end

    it "fails closed per payload if redacting it raises, keeping the rest of the stream redacted" do
      allow(Coolhand).to receive(:log)
      allow(Coolhand::BodyRedactor).to receive(:redact).and_call_original
      allow(Coolhand::BodyRedactor).to receive(:redact).with({ "boom" => "sk-1" }).and_raise(StandardError, "sk-1")
      stream = %(data: {"boom":"sk-1"}\ndata: {"password":"p"}\n)

      result = described_class.redact(stream)

      expect(result).to eq(%(data: {"_coolhand_capture_skipped":"redaction_failed"}\ndata: {"password":"[REDACTED]"}\n))
      expect(Coolhand).to have_received(:log).with(satisfy { |m| m.include?("StandardError") && !m.include?("sk-1") })
    end

    it "redacts a payload that contains NaN or Infinity, which strict JSON would reject" do
      stream = %(data: {"password":"p","logprob":NaN,"n":-Infinity}\ndata: {"a":NaN}\n)

      result = described_class.redact(stream)

      expect(result).to eq(%(data: {"password":"[REDACTED]","logprob":NaN,"n":-Infinity}\ndata: {"a":NaN}\n))
    end

    it "does not let a duplicated key hide a credential from the redaction walk" do
      stream = [
        %(data: {"api_key":"sk-1","api_key":null}),
        %(data: {"a":{"password":"p","password":{}},"b":[{"authorization":"x","authorization":1}]}),
        %(data: {"ok":1,"ok":2})
      ].join("\n")

      result = described_class.redact(stream)

      expect(result).not_to match(/sk-1|"p"|"x"/)
      expect(result.lines.first).to eq(%(data: {"api_key":null}\n))
    end

    it "fails closed with a marker for a body in an encoding Ruby cannot convert" do
      allow(Coolhand).to receive(:log)

      result = described_class.redact((+%(data: {"api_key":"sk-1"})).force_encoding("UTF-7"))

      expect(result).to eq("_coolhand_capture_skipped" => "redaction_failed")
    end

    it "fails closed with a marker for the whole body if the scan itself raises" do
      allow(described_class).to receive(:redact_stream).and_raise(StandardError, "boom api_key=sk-1")
      allow(Coolhand).to receive(:log)

      result = described_class.redact(%(data: {"api_key":"sk-1"}))

      expect(result).to eq("_coolhand_capture_skipped" => "redaction_failed")
      expect(Coolhand).to have_received(:log).with(satisfy { |m| m.include?("StandardError") && !m.include?("sk-1") })
    end

    it "redacts a stream that starts with a byte order mark" do
      result = described_class.redact("\uFEFFdata: {\"api_key\":\"sk-1\"}\n\ndata: {\"a\":1}\n")

      expect(result).to eq("\uFEFFdata: {\"api_key\":\"[REDACTED]\"}\n\ndata: {\"a\":1}\n")
    end

    it "redacts a body in a non-UTF-8 encoding without mangling its other characters" do
      latin1 = %(data: {"api_key":"sk-1","t":"caf\u00E9"}\n).encode(Encoding::ISO_8859_1)
      utf16 = %(data: {"api_key":"sk-1"}\n).encode(Encoding::UTF_16LE)

      expect(described_class.redact(latin1)).to eq(%(data: {"api_key":"[REDACTED]","t":"caf\u00E9"}\n))
      expect(described_class.redact(utf16)).to eq(%(data: {"api_key":"[REDACTED]"}\n))
    end

    it "does not mutate a binary-tagged input that has to be scrubbed" do
      input = "data: {\"api_key\":\"sk-1\",\"t\":\"\xFF\"}\n".b
      snapshot = input.dup

      described_class.redact(input)

      expect(input).to eq(snapshot)
      expect(input.encoding).to eq(Encoding::BINARY)
    end

    it "scales linearly on a large stream" do
      line = %(data: {"choices":[{"delta":{"content":"tok"}}]}\n\n)
      big = "#{line * 20_000}data: {\"api_key\":\"sk-1\"}\n"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.redact(big)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result).to end_with(%(data: {"api_key":"[REDACTED]"}\n))
      expect(elapsed).to be < 5
    end

    it "leaves plain text and an empty String alone" do
      expect(described_class.redact("")).to eq("")
      expect(described_class.redact("just some text with api_key")).to eq("just some text with api_key")
    end

    context "with raw JSON text" do
      it "redacts and re-serializes a JSON object String" do
        result = described_class.redact(%({"event":"x","data":{"password":"p","n":1}}))

        expect(JSON.parse(result)).to eq("event" => "x", "data" => { "password" => "[REDACTED]", "n" => 1 })
      end

      it "re-serializes JSON text compactly even when nothing needed redacting" do
        expect(described_class.redact(%({\n  "a": 1\n}\n))).to eq(%({"a":1}))
      end

      it "redacts JSON text that starts with a byte order mark" do
        expect(JSON.parse(described_class.redact("\uFEFF{\"password\":\"p\"}"))).to eq("password" => "[REDACTED]")
      end

      it "does not let a duplicated key hide a credential in JSON text" do
        expect(described_class.redact(%({"password":"hunter2","password":null}))).to eq(%({"password":null}))
      end

      it "still scans data: lines when the body starts with { or [ but is not one JSON document" do
        log_first = %([INFO] started\ndata: {"api_key":"sk-1"}\n)

        expect(described_class.redact(log_first)).to eq(%([INFO] started\ndata: {"api_key":"[REDACTED]"}\n))
      end

      it "leaves malformed JSON alone" do
        expect(described_class.redact(%({"password":"p",))).to eq(%({"password":"p",))
      end

      it "replaces JSON nested past the depth guard with the marker" do
        deep = ("[" * 150) + ("]" * 150)

        expect(JSON.parse(described_class.redact(deep))).to eq("_coolhand_capture_skipped" => "nesting_too_deep")
      end
    end
  end

  describe "via BodyRedactor.redact" do
    it "dispatches String bodies here and still returns non-container, non-String values as is" do
      expect(Coolhand::BodyRedactor.redact(%(data: {"api_key":"sk-1"}))).to eq(%(data: {"api_key":"[REDACTED]"}))
      expect(Coolhand::BodyRedactor.redact(nil)).to be_nil
      expect(Coolhand::BodyRedactor.redact(5)).to eq(5)
    end
  end
end
