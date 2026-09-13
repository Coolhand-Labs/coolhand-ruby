# Examples

Small, runnable scripts that exercise Coolhand against a real provider API
call. Each script configures `Coolhand` with `silent: false`, so a
successful run prints a `COOLHAND: 📤 Sent complete request/response log for
...` line — that line is the confirmation that the request was actually
intercepted and logged, not just that the provider call succeeded.

These are used by the `/prep-release` skill as a live smoke test before a
release ships, and are just as useful to run by hand when working on the
interceptor code.

## Prerequisites

Set `COOLHAND_API_KEY` plus the API key for whichever provider script you
want to run:

| Script | Required env var |
|---|---|
| `openai_example.rb` | `OPENAI_API_KEY` |
| `anthropic_example.rb` | `ANTHROPIC_API_KEY` |
| `elevenlabs_example.rb` | `ELEVENLABS_API_KEY` |

A script whose `COOLHAND_API_KEY` or provider key isn't set exits `0` with
a message saying it skipped — that's expected in an environment that
doesn't have every key configured, and isn't treated as a failure. Each
script checks `COOLHAND_API_KEY` first specifically so a missing Coolhand
key can't be mistaken for a clean run: without it, Coolhand's own client
silently skips shipping the log for a request rather than raising.

## Running

```bash
bundle install
bundle exec ruby examples/openai_example.rb
bundle exec ruby examples/anthropic_example.rb
bundle exec ruby examples/elevenlabs_example.rb
```

## Why no Vertex example

Vertex AI interception (`aiplatform.googleapis.com`) is fully passive —
Coolhand intercepts it automatically with no dedicated call pattern, and
authenticating a real call requires Google credentials rather than a
single API key env var (see [`docs/vertex.md`](../docs/vertex.md)). That
doesn't fit this directory's "one env var, one script" shape, so it's
intentionally left out.
