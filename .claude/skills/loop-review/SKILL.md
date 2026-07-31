---
name: loop-review
description: |
  Iteratively runs code review against the current diff, applies fixes, and
  re-reviews until a round comes back clean (or a safety cap is hit). Use
  when the user types /loop-review, asks to "loop the review", "review
  until clean", "keep reviewing and fixing until nothing's left", or wants
  a self-healing code review cycle instead of a single one-shot pass.
user_invocable: true
version: 0.3.0
---

# Loop Review

This skill runs `/code-review` repeatedly against the working diff, applies
fixes between rounds, and re-reviews until a round finds nothing new or a
safety cap is reached. Use it after a merge, a large diff, or whenever a
single review pass isn't enough to converge on a clean state.

## Scope

Default scope is the diff between the current branch and its merge-base
with the repo's base branch (`git diff $(git merge-base origin/main
HEAD)...HEAD`, or `origin/main` substituted with whatever base branch
applies). If `$ARGUMENTS` names a path or a narrower scope, review only
that instead of the full diff.

This skill is deliberately diff-scoped. For a whole-package audit before a
release (full-codebase security red-team, docs review, everything since
the last tag) use `/prep-release` instead.

`$ARGUMENTS` may also contain:
- An effort level to pass through to `/code-review` (`low`/`medium`/
  `high`/`high→max`/`ultra`). Default: `medium`.
- A round cap override, e.g. `--max-rounds 3`. Default: 5.

## The round loop

1. Invoke `/code-review <effort> --fix` (via the `Skill` tool) against the
   current scope.
2. **Dry round (0 findings) → converged.** Stop and move to verification.
3. **Findings found and fixed** → do not declare victory yet. Run another
   round to confirm the fixes didn't introduce a regression and that
   nothing was missed.
4. **No-progress detection**: if two consecutive rounds return the same
   non-empty set of findings, `--fix` isn't resolving them mechanically
   (likely a design/architecture call that needs a human). Stop looping,
   list the stuck findings, and hand them to the user instead of retrying
   forever.
5. **Safety cap**: if the round cap is reached without converging or
   getting stuck, stop and report the remaining findings — don't loop
   silently past the cap.

Each round's fixes should stay reviewable: don't squash multiple rounds
into one silent edit. Note per-round changes in the final summary so the
user can inspect them with `git diff`.

## Review criteria

Beyond whatever `/code-review` already checks for correctness bugs and
reuse/simplification/efficiency, every round in a Ruby gem repo like this
one should also flag:

- **Ruby idiom / DRY**: semantic, expressive naming; no duplicated logic
  that should be extracted into a shared method; idiomatic use of
  Ruby/Enumerable over manual loops where it reads better; no needless
  boilerplate.
- **Gem publishing discipline**: don't break public interfaces unless
  necessary.
  - If a break is necessary, it must come with: a `CHANGELOG.md` entry in
    Keep a Changelog format (this repo already follows that format — match
    the style of existing entries, e.g. plain-English migration notes like
    the `0.5.0` entry) and a version bump in `lib/coolhand/version.rb` that
    matches SemVer (patch = fix, minor = backward-compatible addition,
    minor = breaking change while pre-1.0, consistent with this repo's own
    versioning history).
  - Check the optional-provider-dependency rule from this repo's
    `CLAUDE.md`: provider SDK `require`s (`openai`, `anthropic`,
    `google-generativeai`, etc.) must stay scoped to the file that uses
    them and lazy-loaded, never added to `lib/coolhand.rb` or the gemspec
    as a hard dependency.
- **Security**: injection risks, unsafe deserialization, secrets or
  credentials logged or committed, unvalidated input crossing a trust
  boundary, and anything touching how API keys/tokens are handled,
  stored, or transmitted.

## Post-loop verification

Once the loop converges (or stops early per the rules above), run the
project's lint/test command and include the result in the final summary.
For this repo that's `bundle exec rake` (runs `rspec` then `rubocop`, per
the `Rakefile`). If a fix round changed something outside this repo's
usual toolchain, discover the right command instead of assuming.

## Rationalizations to resist

- *"The first round already looked clean, I don't need a confirming
  round."* A fix round can introduce its own regression. Always re-review
  after applying fixes before declaring convergence.
- *"Rubocop passed, so the review is done."* Lint passing is not the same
  as the review being clean — lint doesn't check the criteria above
  (interface breakage, changelog/version discipline, security). Run both.
- *"This finding keeps coming back, I'll just keep re-running --fix and
  it'll eventually take."* If the same non-empty finding set repeats
  across two rounds, `--fix` isn't going to resolve it. Stop and surface
  it — looping past that point just burns rounds for no gain.

## Safety

- Never force-push or amend existing commits as part of this loop.
- The skill only edits the working tree; committing and pushing stays with
  the user.
