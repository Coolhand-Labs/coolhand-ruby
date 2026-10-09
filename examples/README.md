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

## Benchmark: `benchmark_async_logging.rb`

Unlike the scripts above, this one is a pass/fail performance check for async logging
(`config.async_logging`): it measures how much latency Coolhand adds to an intercepted call and
whether a slow Coolhand backend leaks into it. It exits non-zero if an assertion fails, so
`/prep-release` picks it up when it runs every script in this directory. With no keys set it runs
only the local scenario and exits 0; the live scenario is skipped.

```bash
bundle exec ruby examples/benchmark_async_logging.rb          # N=8 calls per mode
N=20 bundle exec ruby examples/benchmark_async_logging.rb     # tighter numbers
```

| Scenario | Needs | What it checks |
|---|---|---|
| Local | nothing (fake LLM + fake Coolhand that takes 2s to reply) | sync mode pays the full 2s per call; async adds <= 250ms (median) vs. capture off; the queue drains; every log is delivered |
| Live | `COOLHAND_API_KEY` plus `OPENAI_API_KEY` and/or `ANTHROPIC_API_KEY` | per provider: async adds <= 200ms vs. capture off (fastest call, since provider latency is too noisy to compare medians); all logs delivered with no failed POSTs |

Each mode (`capture off`, `async_logging = false`, `async_logging = true`) is run `N` times,
interleaved per iteration so provider drift hits all three equally. The live scenario sends
`2N + 1` small real logs per provider to your Coolhand account and costs a negligible amount of
provider usage. A last check confirms the interceptor adds no generically named helper methods to
`Net::HTTP`.

## Why no Vertex example

Vertex AI interception (`aiplatform.googleapis.com`) is fully passive —
Coolhand intercepts it automatically with no dedicated call pattern, and
authenticating a real call requires Google credentials rather than a
single API key env var (see [`docs/vertex.md`](../docs/vertex.md)). That
doesn't fit this directory's "one env var, one script" shape, so it's
intentionally left out.
