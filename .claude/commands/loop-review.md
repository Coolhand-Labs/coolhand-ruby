---
description: Automated review → fix → repeat loop. Spawns a reviewer agent each round, fixes findings in this session, and repeats until the review comes back clean.
argument-hint: [low|medium|high|max]
---

Run an automated code review + fix loop on the current branch. Keep iterating until the reviewer reports no issues.

## Setup

- Effort level: `$ARGUMENTS` (default: `high` if blank)
- Max iterations: 5
- Review scope: `git diff origin/main...HEAD`

## Loop Instructions

Repeat the following cycle up to 5 times:

### Step 1 — Review (Agent)

Spawn an Agent using the Agent tool with `thinking: "high"` enabled and this prompt (substitute ITERATION_NUM, EFFORT, and PREVIOUS_FIXES):

---
You are a code reviewer doing pass ITERATION_NUM of an automated review loop for the `coolhand-ruby` gem.

Run `git diff origin/main...HEAD` to get the current branch diff. Review it for:

**Correctness & quality**
- Correctness bugs and logic errors
- Missing/broken error handling — note that interceptor and batch-processor code paths deliberately swallow `StandardError` and log rather than raise (never let Coolhand instrumentation crash the host app); flag both missing rescues in new instrumentation code AND overly broad rescues that would hide real bugs elsewhere
- Inefficiencies or unnecessary complexity
- Violations of project conventions in CLAUDE.md
- Code reuse opportunities — this gem has near-duplicate `send_complete_request_log` implementations in `lib/coolhand/base_interceptor.rb` and each provider's `batch_result_processor.rb`; new duplication of that shape should be flagged in favor of reuse

**Optional provider dependencies (hard requirement, see CLAUDE.md)**
- Any `require` of a provider SDK (`openai`, `anthropic`, `google-generativeai`, etc.) MUST live in the specific file where it's used, not in `lib/coolhand.rb` or any file loaded unconditionally
- Provider SDKs MUST NOT be added as a hard `spec.add_dependency` in `coolhand-ruby.gemspec`
- Confirm the gem still loads cleanly with no provider gems installed

**Security**
- Secrets, API keys, or auth headers logged or sent unredacted — any new code path that sends a payload to the Coolhand API should route headers through `sanitize_headers`/`clean_request_headers` and URLs through `sanitize_url` (see `lib/coolhand/base_interceptor.rb`) rather than reinventing redaction
- Injection vulnerabilities, unsafe use of user-supplied input
- Sensitive data (raw request/response bodies with credentials, PII) captured without the user's `capture`/`without_capture` opt-out being respected

**Backwards compatibility (public gem API)**
- Breaking changes to the public surface in `lib/coolhand.rb` (`Coolhand.configure`, `Coolhand.capture`, `Coolhand.without_capture`) or `Coolhand::Configuration` options that were NOT the stated intent of this branch
- Renamed/removed public methods or classes under `lib/coolhand/` without a clear migration path
- Changes to `lib/coolhand/default_intercept_addresses.yml` or `lib/coolhand/default_exclude_api_patterns.yml` that silently drop previously-covered hosts/patterns instead of additively extending them
- `lib/coolhand/version.rb` bumped appropriately (semantic versioning) when the diff changes public behavior

**Coolhand API accuracy**
- Where the diff builds a payload sent via `Coolhand::ApiService` (e.g. `send_llm_request_log`, `create_feedback`) or a webhook handler, fetch the current published API docs from coolhandlabs.com and verify the request shape (field names, required vs optional, endpoint path/version) matches
- Flag any new top-level payload fields whose acceptance by the ingestion backend hasn't been confirmed
- For URL fields sent as part of a synthetic/batch log (not a real intercepted HTTP call), confirm the URL is fully-qualified (`scheme://host/path`) rather than a bare provider resource path — bare paths break backend `source_api`/`model` classification (see #76)

**Documentation (see CLAUDE.md's "README and docs philosophy")**
- Config beyond the basic `Coolhand.configure` snippet belongs in `docs/configuration.md`, not the README
- Feedback beyond the basic `create_feedback` snippet belongs in `docs/feedback.md`
- Each provider/framework integration gets its own `docs/<name>.md`, linked from the README's Documentation section
- Headings and provider names should use full names for SEO/AEO ("OpenAI", "Anthropic", "Google Gemini") rather than abbreviations
- Missing `CHANGELOG.md` `[Unreleased]` entry for user-visible changes (new config options, new default intercept addresses, behavior changes, bug fixes)
- Stale README/docs left inconsistent with the code change

**Testing**
- New/changed behavior lacks corresponding RSpec coverage under `spec/coolhand/`
- Existing specs weakened (loosened matchers, removed assertions) to make them pass rather than fixing the underlying code
- Would `bundle exec rspec` and `bundle exec rubocop` catch this? If a lint or test gap is obvious, flag it

Effort: EFFORT

Already fixed in prior iterations — do NOT re-flag these:
PREVIOUS_FIXES

Return a numbered list of issues with file path and line numbers. Be specific about what to fix and why.
If there are NO issues, respond with exactly: LGTM: No issues found.
---

### Step 2 — Check Result

- If the agent says `LGTM: No issues found.` → exit the loop, go to Final Summary
- If iteration count has reached 5 → exit the loop, go to Final Summary (partial)
- Otherwise → proceed to Step 3

### Step 3 — Fix

Fix EVERY issue the reviewer raised. Use Edit, Write, and Bash tools to apply fixes directly. Do not skip any finding. After fixing, run `bundle exec rspec` and `bundle exec rubocop` to confirm the fixes don't break tests or introduce lint offenses.

### Step 4 — Log & Continue

Record this iteration in your running log (see format below), then go back to Step 1 with the next iteration number.

## Iteration Log Format

Maintain this log as you work:

```
=== Iteration 1 ===
Reviewer found N issues:
  1. [file:line] description
  2. ...
Fixed:
  - Applied: [description of fix]
  - Applied: [description of fix]

=== Iteration 2 ===
...

=== RESULT ===
[CLEAN after N iterations] or [STOPPED at max iterations — N issues remain]
```

## Final Summary

After the loop exits, output:

1. **Overall result**: CLEAN (N iterations) or STOPPED (issues remain)
2. **Per-iteration breakdown**: What was found vs. what was fixed each round
3. **All files modified**: Complete list of files touched across all iterations
4. **Remaining issues** (if stopped at max): Unresolved items with context on why they're hard to fix automatically
