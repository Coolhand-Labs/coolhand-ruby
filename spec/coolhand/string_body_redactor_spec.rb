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

    it "leaves non-JSON data lines alone and still redacts the good ones" do
      stream = [
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

      expect(result.lines[0..7].join).to eq(stream.lines[0..7].join)
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

      it "leaves malformed JSON without a credential-named string value alone" do
        expect(described_class.redact(%({"note":"p",))).to eq(%({"note":"p",))
      end

      it "scrubs a credential-named string value in malformed JSON, keeping the rest of the text" do
        expect(described_class.redact(%({"password":"p","n":1,))).to eq(%({"password":"[REDACTED]","n":1,))
      end

      it "replaces JSON nested past the depth guard with the marker" do
        deep = ("[" * 150) + ("]" * 150)

        expect(JSON.parse(described_class.redact(deep))).to eq("_coolhand_capture_skipped" => "nesting_too_deep")
      end
    end
  end

  describe "JSON cut off mid-line (a stream that was abandoned or dropped)" do
    it "scrubs a credential-named value that was cut off before its closing quote" do
      stream = %(data: {"id":"1","n":2}\n\ndata: {"tools":[{"authorization":"Bearer sk-LIVE-12)

      result = described_class.redact(stream)

      expect(result).to eq(%(data: {"id":"1","n":2}\n\ndata: {"tools":[{"authorization":"[REDACTED]"))
      expect(result).not_to include("sk-LIVE")
    end

    it "scrubs a value cut off right after a backslash or inside an escape" do
      expect(described_class.redact(%(data: {"api_key":"sk-1\\))).to eq(%(data: {"api_key":"[REDACTED]"))
      expect(described_class.redact(%(data: {"api_key":"sk-1\\u00))).to eq(%(data: {"api_key":"[REDACTED]"))
    end

    it "scrubs a terminated credential value whose line is cut off after it" do
      result = described_class.redact(%(data: {"apiKey":"sk-1","choices":[{"delta":{"con))

      expect(result).to eq(%(data: {"apiKey":"[REDACTED]","choices":[{"delta":{"con))
    end

    it "matches key names the way BodyRedactor does: case, separators and unicode escapes" do
      result = described_class.redact(%(data: {"Client-Secret":"s1","\\u0061pi_key":"s2","x-api-key":"s3","tok))

      expect(result).to eq(
        %(data: {"Client-Secret":"[REDACTED]","\\u0061pi_key":"[REDACTED]","x-api-key":"[REDACTED]","tok)
      )
    end

    it "does not scrub non-credential keys, or a credential name that only appears inside another value" do
      stream = %(data: {"text":"say \\"api_key\\": \\"x\\"","token":"Hello","usage":{"total_tokens":1},"c)

      expect(described_class.redact(stream)).to eq(stream)
    end

    it "decodes a key whose escape the JSON parser rejects leniently, so its value is still scrubbed" do
      expect(described_class.redact(%(data: {"api\\_key":"v","n":))).to eq(%(data: {"api\\_key":"[REDACTED]","n":))
      expect(described_class.redact(%(data: {"api\\_key":"v"}))).to eq(%(data: {"api\\_key":"[REDACTED]"}))
    end

    it "mixes a valid unicode escape and an invalid one in a credential key" do
      expect(described_class.redact(%({"\\u0061pi\\_key":"v","n":))).to eq(%({"\\u0061pi\\_key":"[REDACTED]","n":))
    end

    it "scrubs trailing text after an otherwise valid payload" do
      expect(described_class.redact(%(data: {"api_key": "sk-1", broken)))
        .to eq(%(data: {"api_key": "[REDACTED]", broken))
    end

    it "leaves non-string credential values alone, as the parsed path does" do
      body = %(data: {"password":12,"secret":{"value":"x"},"authorization":["Bearer x"],"api_key":null,"n":)

      expect(described_class.redact(body)).to equal(body)
    end

    it "keeps pairs aligned across arrays of strings, colons and credential names inside values, and odd spacing" do
      {
        %(["a","b"],"api_key":"S","z) => %(["a","b"],"api_key":"[REDACTED]","z),
        %({"a":"api_key","password":"S","z) => %({"a":"api_key","password":"[REDACTED]","z),
        %({"a":"x:y","api_key":"S") => %({"a":"x:y","api_key":"[REDACTED]"),
        %({"":"x","api_key":"S") => %({"":"x","api_key":"[REDACTED]"),
        %({"api_key"\n:\r\n"S","n) => %({"api_key"\n:\r\n"[REDACTED]","n),
        %({"a":1,"api_key":"S","n) => %({"a":1,"api_key":"[REDACTED]","n)
      }.each do |body, expected|
        expect(described_class.redact(body)).to eq(expected)
      end
    end

    it "scrubs newline-delimited JSON and a byte-order-marked or CRLF body that does not parse" do
      expect(described_class.redact(%({"a":1}\n{"api_key":"sk-1"}))).to eq(%({"a":1}\n{"api_key":"[REDACTED]"}))
      expect(described_class.redact(%(\uFEFF{"api_key":"sk-1","n":))).to eq(%(\uFEFF{"api_key":"[REDACTED]","n":))
      expect(described_class.redact(%(data: {"api_key":"sk-1"}\r\ndata: {"password":"p","n":)))
        .to eq(%(data: {"api_key":"[REDACTED]"}\r\ndata: {"password":"[REDACTED]","n":))
    end

    it "scrubs a cut-off body held in a binary-tagged String with invalid UTF-8" do
      binary = %(data: {"api_key":"sk-\xFF1","n":).b

      expect(described_class.redact(binary)).to eq(%(data: {"api_key":"[REDACTED]","n":))
    end

    it "stays linear on megabyte-sized adversarial text (escaped quotes, bare quotes, tiny pairs)" do
      bodies = [%(data: {"#{'\\"' * 500_000}), "{#{'"' * 1_000_000}", %({#{'"a":"b",' * 120_000}"c)]

      bodies.each do |body|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        described_class.redact(body)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      end
    end

    it "scrubs a truncated JSON text body, not only data: lines" do
      result = described_class.redact(%({"data":{"password":"hunter2","n":))

      expect(result).to eq(%({"data":{"password":"[REDACTED]","n":))
    end

    it "returns the original String when nothing in a cut-off body needed scrubbing" do
      body = %(data: {"id":"1","choices":[{"delta":{"content":"Hel)

      expect(described_class.redact(body)).to equal(body)
    end

    it "keeps a rewritten data line's own whitespace and scrubs a later cut-off line too" do
      result = described_class.redact(%(data:  {"password":"p"}\ndata: {"secret":"cut))

      expect(result).to eq(%(data:  {"password":"[REDACTED]"}\ndata: {"secret":"[REDACTED]"))
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
