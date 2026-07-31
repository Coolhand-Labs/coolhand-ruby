---
name: prep-release
description: |
  Prepares this gem for a release: runs the full test suite, updates and
  cleans up the docs (README, CHANGELOG, docs/*.md) to reflect every change
  since the last tag, bumps the version if that hasn't already been done,
  and red-teams the whole package for security - not just this release's
  diff. Never tags or pushes. Use when the user types /prep-release, asks
  to "prep a release", "get ready to cut a release", "release checklist",
  or wants a pre-release audit before tagging/publishing a new version.
user_invocable: true
version: 0.2.0
---

# Prep Release

Three phases, run in order. This is a whole-package audit, not a diff
review — do not scope any phase to just what changed since the last
commit. For an iterative diff-scoped review during normal development, use
`/loop-review` instead; this skill is for the release boundary.

## Phase 1: Run all tests

Run `bundle exec rake` (`rspec` then `rubocop`, per the `Rakefile`). If a
fix round changed something outside this repo's usual toolchain, discover
the right command instead of assuming. All specs must pass and RuboCop
must report zero offenses before continuing — a release doesn't ship on a
red build. If either fails, stop here and report the failures; fixing
genuine bugs takes priority over Phase 2/3 work.

Then judge coverage on quality, not just the SimpleCov percentage the rake
run reports (written to `coverage/`):

1. **Find the gaps.** List files/lines SimpleCov marks uncovered. Weight
   by risk: an uncovered error-handling branch or security check
   (signature/header validation) matters more than an uncovered
   `attr_reader`.
2. **Audit existing tests for meaningfulness, not just count.** Flag tests
   that only assert a stub returns what it was stubbed to return without
   exercising real conditional logic in the subject under test; missing
   negative/error-path cases (invalid input, malformed provider responses,
   network failure); missing domain edge cases (empty batch results,
   duplicate-request prevention, concurrent access, streaming vs
   non-streaming shapes).
3. **Recommend, don't pad.** Propose specific specs for the highest-risk
   gaps, named by `file:describe/context`. Don't add tests purely to move
   the percentage — a test with no failure mode it would catch adds
   maintenance cost without adding signal.

## Phase 2: Update and clean the docs

1. Find the last release tag: `git describe --tags --abbrev=0`.
2. Diff everything since that tag: `git log <last-tag>..HEAD --oneline` and
   `git diff <last-tag>..HEAD -- lib/` to see every behavioral change, not
   just the most recent commit.
3. For each change, check it's reflected in:
   - `CHANGELOG.md` — every notable change since the last tag needs an
     entry under `[Unreleased]` (or a new version heading), in Keep a
     Changelog format matching this repo's existing entries (see past
     entries for style — plain-English migration notes for anything
     behavior-affecting).
   - `README.md` / `docs/*.md` — any new config option, public method, or
     behavior change needs the relevant section updated. Follow this
     repo's docs philosophy from `CLAUDE.md`: the README stays a scannable
     landing page (basic config/feedback snippets only); anything needing
     more than one code block belongs in `docs/`.
4. **Clean, don't just append.** Look for docs that are now stale,
   contradictory, or redundant given the accumulated changes since the
   last tag — consolidate/rewrite rather than layering a new paragraph on
   top of an outdated one. Remove docs for anything removed from the gem.
5. **Bump the version if it hasn't already been done.** Check whether
   `lib/coolhand/version.rb` was already bumped for the changes
   accumulated since the last tag (e.g. by an earlier commit on this
   branch) — if so, leave it. If not, determine the SemVer bump this
   repo's convention implies (patch = fix, minor = backward-compatible
   addition or breaking change while pre-1.0), write it to
   `lib/coolhand/version.rb`, turn the `[Unreleased]` CHANGELOG heading
   into `## [X.Y.Z] - <today's date>`, and run `bundle install` so
   `Gemfile.lock`'s `coolhand (X.Y.Z)` line matches. State the version and
   bump rationale in the wrap-up summary so the user can override it if
   they'd have picked differently — don't ask before writing it, since
   this is a mechanical, reversible edit gated by Phase 1's green build.

## Phase 3: Red-team the whole package

Adversarially review the entire `lib/` tree (not just this release's
diff) for security issues. This gem intercepts outgoing LLM API traffic
and logs it to Coolhand, so hunt specifically for:

- **Credential/secret leakage**: does any interceptor, logger, or error
  handler write an API key, bearer token, or provider auth header value
  into a log line, exception message, or the payload sent to Coolhand?
  Check every header-sanitization path actually strips what it claims to
  (e.g. `WebhookValidator`, provider header redaction) rather than
  sanitizing a differently-cased or differently-named header.
- **Webhook/signature validation**: can `WebhookValidator#valid?` (or
  equivalent) be bypassed — timing-unsafe comparison instead of a
  constant-time compare, an environment where an empty/missing signature
  is treated as valid, or a fallback path meant for development that's
  reachable in production.
- **SSRF / address matching**: the default and configurable intercept
  address lists — can a crafted URL (redirect, unicode homograph,
  userinfo trick, subdomain confusion) match or evade the intended
  host-matching logic in a way that intercepts (or fails to intercept)
  the wrong destination?
- **ReDoS**: any regex built from configurable or user-influenced input
  (intercept patterns, header names) — check for catastrophic backtracking
  shapes (nested quantifiers, overlapping alternation).
- **Thread safety**: this gem documents thread-safe operation and
  duplicate-request prevention — look for unsynchronized shared mutable
  state (class-level `@@` vars, memoized `@client` on a shared instance)
  that a concurrent request could race on.
- **Unsafe deserialization**: any `JSON.parse` without checking for
  `Marshal.load`/`YAML.load` (unsafe) usage, and any parsing of
  webhook/batch-result payloads that trusts attacker-controlled shape
  without validation.
- **Fail-open vs fail-closed**: when Coolhand's API is unreachable, rate
  limited, or returns malformed data, does the gem fail open in a way that
  silently drops security-relevant logging, or fail in a way that breaks
  the host application's actual LLM call (the interceptor must never break
  the underlying request)?

For each finding, report file, line, a concrete failure scenario, and
severity. Apply safe, mechanical, low-risk fixes directly (e.g. a missing
header-redaction pattern, a missing timeout). Flag but do not silently
apply anything that's a behavior/architecture decision (e.g. changing a
fail-open security default, adding replay protection, moving synchronous
work to a background thread) — surface these to the user for a decision,
the same "hand it to a human" rule `/loop-review` uses for stuck findings.

## Wrap-up

Report one consolidated summary: test/lint result, coverage-quality gaps
plus recommended specs, docs updated, the version (bumped or already
current, and why), and security findings split into fixed vs.
flagged-for-decision.

## Safety

- Bumping `lib/coolhand/version.rb`, finalizing the CHANGELOG heading, and
  running `bundle install` for the lockfile are all in scope and don't need
  a stop-and-ask — they're mechanical, reversible, and gated on Phase 1
  already being green.
- Never create or push a git tag, never push commits, and never run
  `rake release`, `gem push`, or anything else that publishes the gem or
  touches the remote. Tagging and publishing are the user's action once
  they've reviewed this skill's report, not something this skill does.

## Rationalizations to resist

- *"The diff since the last tag is small, I'll skip the red-team."* Small
  diffs can still sit on top of latent issues in code nobody's touched
  recently — that's exactly what "whole package, not just the diff" means.
- *"Tests pass, so coverage is fine."* Passing tests and meaningful
  coverage are different questions. A red build blocks release; a green
  build with hollow tests doesn't guarantee anything.
- *"Docs are close enough, I'll skip the cleanup pass."* Accumulated
  changes since the last tag are exactly when docs drift from behavior —
  this phase exists because per-PR doc updates miss the cross-cutting
  view.
