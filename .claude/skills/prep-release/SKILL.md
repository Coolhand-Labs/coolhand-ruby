---
name: prep-release
description: |
  Runs an entire release event for this gem: triages every open PR into a
  quality/risk-rated merge recommendation, waits for the user's sign-off,
  squash-merges the chosen PRs, writes the release's changelog and version
  bump plus a whole-package security red-team on its own release branch,
  validates that branch with the full test suite and live-key example
  apps, then opens a single release-prep PR for the user's final review.
  Never merges that PR, tags, or publishes. Use when the user types
  /prep-release, asks to "prep a release", "cut a release", "release
  checklist", or wants the open PRs triaged and merged into a release.
user_invocable: true
version: 1.0.0
---

# Prep Release

Five phases, run in order. This is a whole-release audit, not a
single-branch review — Phase 3 onward operates on the whole `lib/` tree and
everything merged since the last tag, not just one diff. For an iterative
diff-scoped review during normal development, use `/loop-review` instead;
this skill is for the release event itself.

Per `CLAUDE.md`, feature/fix branches never touch `CHANGELOG.md` or
`lib/coolhand/version.rb` — this skill is the only place those get written.
If a chosen PR's diff does touch either file, treat it as a normal part of
that PR's diff (don't strip it), but don't let it change how Phase 3 writes
its own entry — Phase 3's changelog write-up is authoritative regardless of
what an individual PR's diff already contains.

## Phase 1: Survey open PRs, recommend a release set

1. `gh pr list --state open --json number,title,author,isDraft,mergeable,mergeStateStatus,statusCheckRollup,additions,deletions,changedFiles,body,headRefName`.
2. For each PR, pull `gh pr diff <n>` and `gh pr checks <n>` and rate two
   independent axes:
   - **Quality** (High/Medium/Low): does the diff include spec coverage
     proportional to the `lib/` change, is the code consistent with this
     repo's style/conventions, does the PR description read as complete
     work rather than a stub or "WIP, not ready" note.
   - **Risk** (High/Medium/Low): does it touch a security- or
     interception-critical path (`net_http_interceptor.rb`,
     `webhook_validator.rb`, `base_interceptor.rb`, anything under
     `default_intercept_addresses.yml`/`default_exclude_api_patterns.yml`)
     — weight those higher regardless of size; failing CI checks or a
     non-clean `mergeable` state also push risk up; an isolated additive
     feature or docs-only change is lower risk.
3. Present one table: PR number, title, quality, risk, CI status,
   mergeable state, and a one-line recommendation (include / exclude /
   needs work before it can be considered). Call out anything that looks
   unfinished — draft, a WIP-sounding title, failing checks, an empty or
   placeholder description, visible `TODO`/`FIXME` in the diff — as
   "exclude, not ready" rather than rating it neutrally.
4. Stop here and ask the user which PRs to include in this release. This
   is the one planned decision point in the whole skill — do not merge,
   write changelog entries, or touch `version.rb` until the user answers.
   (Phase 2 step 3 below has its own unplanned-error stop for an unclean
   working tree; that's an abort on unexpected state, not a second
   decision point like this one.)

## Phase 2: Merge the chosen PRs

Process the user's chosen PRs one at a time, not as a batch:

1. Before each merge, re-check that PR's `mergeable`/`mergeStateStatus`
   (`gh pr view <n> --json mergeable,mergeStateStatus`) — an earlier merge
   in this same run can newly conflict a later one. If a chosen PR now
   conflicts, skip it, note it in the running list as "skipped — needs
   rebase," and continue with the rest. Don't resolve conflicts on someone
   else's branch unilaterally.
2. `gh pr merge <n> --squash --delete-branch` for each surviving PR.
3. After each merge, sync local `main` before evaluating the next PR.
   First check `git status --porcelain` — if it's not empty, stop and
   surface it to the user rather than discarding unknown local state;
   otherwise `git fetch origin main && git checkout main && git reset
   --hard origin/main` is safe, since it only overwrites a working tree
   already confirmed clean with the just-fetched remote `main`.

Keep a running list of what actually merged vs. what got skipped — Phase 5
reports both.

## Phase 3: Build the release branch — docs/changelog/version + red-team

Create `release/vX.Y.Z` off the freshly synced `main` (version number per
step 5 below) and do all of the following as commits on that branch —
never on `main` directly.

### Docs, changelog, version

1. Find the last release tag: `git describe --tags --abbrev=0`.
2. Diff **everything since that tag** on the now-updated `main` —
   `git log <last-tag>..HEAD --oneline` and `git diff <last-tag>..HEAD -- lib/`
   — not just the PRs this run merged in Phase 2. `main` can carry
   unreleased changes Phase 2 never touched (a hotfix committed directly,
   a PR merged manually outside this skill, or a prior `/prep-release` run
   that merged PRs but was interrupted before finishing this phase); all
   of those still need a changelog entry, so treat this diff, not Phase
   2's merge list, as the source of truth for what's covered.
3. For each change, check it's reflected in:
   - `CHANGELOG.md` — one entry per change under `[Unreleased]` (or a new
     version heading), in Keep a Changelog format matching this repo's
     existing entries — plain-English migration notes for anything
     behavior-affecting. Attribute each entry to its PR number where one
     exists: check Phase 2's merge list first, then fall back to the
     squash-merge commit message (`git log --grep`, which carries the PR
     number in its title) for anything not merged in this run. If a
     change genuinely has no discoverable PR (a direct commit to `main`),
     write the entry without one rather than skipping it.
   - `README.md` / `docs/*.md` — any new config option, public method, or
     behavior change needs the relevant section updated. Follow this
     repo's docs philosophy from `CLAUDE.md`: the README stays a scannable
     landing page (basic config/feedback snippets only); anything needing
     more than one code block belongs in `docs/`.
4. **Clean, don't just append.** Look for docs that are now stale,
   contradictory, or redundant given the accumulated changes since the
   last tag — consolidate/rewrite rather than layering a new paragraph on
   top of an outdated one. Remove docs for anything removed from the gem.
5. **Bump the version.** Since `CLAUDE.md` now forbids per-PR bumps, this
   should always be needed — but check `lib/coolhand/version.rb` against
   the last tag first as a defensive sanity check in case something bumped
   it out of band. Determine the SemVer bump this repo's convention
   implies (patch = fix, minor = backward-compatible addition or breaking
   change while pre-1.0), write it to `lib/coolhand/version.rb`, turn the
   `[Unreleased]` CHANGELOG heading into `## [X.Y.Z] - <today's date>`, and
   run `bundle install` so `Gemfile.lock`'s `coolhand (X.Y.Z)` line
   matches.

### Red-team

Adversarially review the entire `lib/` tree (not just what merged in Phase
2) for security issues. This gem intercepts outgoing LLM API traffic and
logs it to Coolhand, so hunt specifically for:

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
severity. Apply safe, mechanical, low-risk fixes directly, as commits on
`release/vX.Y.Z` (e.g. a missing header-redaction pattern, a missing
timeout). Flag but do not silently apply anything that's a
behavior/architecture decision (e.g. changing a fail-open security
default, adding replay protection, moving synchronous work to a
background thread) — surface these to the user for a decision, the same
"hand it to a human" rule `/loop-review` uses for stuck findings.

## Phase 4: Validate the release branch

1. Run `bundle exec rake` (`rspec` then `rubocop`, per the `Rakefile`) on
   `release/vX.Y.Z`. All specs must pass and RuboCop must report zero
   offenses before continuing — a release doesn't ship on a red build. If
   either fails, stop here and report the failures; fixing genuine bugs
   takes priority over the rest of this phase and Phase 5.

   Then judge coverage on quality, not just the SimpleCov percentage the
   rake run reports (written to `coverage/`): find the gaps and weight by
   risk (an uncovered error-handling or security-check branch matters more
   than an uncovered `attr_reader`); audit existing tests for
   meaningfulness, not just count (flag tests that only assert a stub
   returns what it was stubbed to return, missing negative/error-path
   cases, missing domain edge cases); recommend specific specs for the
   highest-risk gaps, named by `file:describe/context` — don't add tests
   purely to move the percentage.

2. If Phase 4.1 is green, run every script in `examples/` against live
   provider keys: `bundle exec ruby examples/<name>.rb` for each. Each
   script is expected to skip itself cleanly (exit 0, clear message) if
   its provider's API key isn't set in this environment — treat that as a
   skip, not a failure. Record pass/skip/fail per script. A script that
   exits non-zero with a key present is a real failure and should be
   investigated before continuing to Phase 5 — it means this release
   would ship with broken interception or a broken provider integration.

## Phase 5: Open the release-prep PR, report everything

1. Push `release/vX.Y.Z` and `gh pr create` (e.g. "chore: release
   vX.Y.Z") targeting `main`. This PR is the user's final checkpoint
   before the changelog/version/red-team commit lands — never merge it,
   tag it, or run `rake release`/`gem push` yourself.
2. Report one consolidated summary covering the whole run:
   - Phase 1's PR table and which PRs the user chose.
   - Phase 2's outcome: which PRs merged, which were skipped for new
     conflicts (and need a rebase before the next release).
   - The release-prep PR link, the version bump and why.
   - Coverage-quality gaps plus recommended specs.
   - Docs updated.
   - Red-team findings split into fixed vs. flagged-for-decision.
   - Phase 4's regression test/lint result and the example-app run
     results (pass/skip/fail per script).

## Safety

- Bumping `lib/coolhand/version.rb`, finalizing the CHANGELOG heading, and
  running `bundle install` for the lockfile are all in scope and don't
  need a stop-and-ask — they're mechanical, reversible, and gated on Phase
  4 already being green before the PR opens.
- Squash-merging PRs the user explicitly chose in Phase 1, and pushing the
  `release/vX.Y.Z` branch to open its own PR, are both in scope.
- Never push a commit directly to `main`. All release-branch work lands on
  `main` only via the Phase 5 PR, which the user reviews and merges
  themselves.
- Never create or push a git tag, never run `rake release` or `gem push`,
  and never merge the Phase 5 PR yourself. Tagging and publishing are the
  user's action once they've reviewed and merged this skill's PR, not
  something this skill does.

## Rationalizations to resist

- *"This PR's CI is green and the diff is small, I don't need to look at
  the actual diff."* CI passing doesn't rule out unfinished work — a
  small, green diff can still be a stub that leaves a feature half-built.
  Read the diff.
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
- *"The example apps are just smoke tests, I'll skip them since specs
  passed."* Specs mock the provider SDKs; the example apps are the only
  step in this skill that exercises a real API call through real
  interception code — that's a different failure mode than a unit test
  can catch.
