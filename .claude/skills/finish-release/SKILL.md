---
name: finish-release
description: |
  Finishes a release after the user has reviewed the release-prep PR (from
  /prep-release): squash-merges that PR (title "release vX.Y.Z", the PR
  description as the commit body), creates and pushes the annotated vX.Y.Z tag
  on the merge commit, then publishes the GitHub release notes in the same
  format as the previous release. Pushing the tag triggers the Publish
  workflow (RubyGems Trusted Publishing), so this is the step that ships the
  gem. Use when the user types /finish-release, asks to "merge and tag the
  release", "publish the release notes", or "ship v0.x.y".
---

# Finish Release

The counterpart to `/prep-release`. That skill stops at an open release PR and
never merges, tags or publishes; this one starts once the user has reviewed that
PR. Running it is the user's go-ahead to **merge, tag and publish**. Three
steps, in this order: **merge, tag, release notes**. The tag is cut on the merge
commit, and the release is created with `--verify-tag`, so each step needs the
one before it.

**What pushing the tag does:** `.github/workflows/publish.yml` runs on any
`v*.*.*` tag push. It runs the specs and RuboCop, checks the tag matches
`Coolhand::VERSION`, then publishes to RubyGems behind the `rubygems-publish`
environment, which may wait for a human approval. Say so in the final report.

## Phase 1: Preconditions (abort on any failure, change nothing)

1. `git fetch origin --tags`.
2. Find the release-prep PR: head branch `release/vX.Y.Z`, title
   `chore: release vX.Y.Z` (`gh pr list --state open --search "release in:title"
   --json number,title,headRefName,isDraft,mergeStateStatus`). Take `X.Y.Z` from
   it; the tag is `vX.Y.Z`. If there is no open PR, look for a merged one
   (`--state merged`); if it is merged but untagged, skip Phase 2 and continue
   from its merge commit. If there is neither, stop.
3. Read everything from the PR head (`git fetch origin release/vX.Y.Z`, then
   `git show origin/release/vX.Y.Z:<path>`), never the working tree:
   - `lib/coolhand/version.rb` is `X.Y.Z`, and `Gemfile.lock` has
     `coolhand (X.Y.Z)`.
   - `CHANGELOG.md` has a `## [X.Y.Z]` heading and `## [Unreleased]` is empty.
   - `X.Y.Z` is greater than the latest tag (`git describe --tags --abbrev=0
     origin/main`).
4. The PR is open, not a draft, `mergeStateStatus` is `CLEAN`, and every check
   passes (`gh pr checks <n>`). A red or pending check, or a conflict, stops the
   run: report it, don't merge around it.
5. The tag does not already exist, locally (`git tag -l vX.Y.Z`) or on the
   remote (`git ls-remote --tags origin 'vX.Y.Z*'`), and no release exists
   (`gh release view vX.Y.Z` fails). If the tag exists but the release does not,
   skip to Phase 4 after confirming the tag points at the release merge commit.

## Phase 2: Squash-merge the release PR

1. Save the PR description verbatim to a gitignored scratch file:
   `gh pr view <n> --json body --jq .body > .context/release-pr-body.md`.
2. `gh pr merge <n> --squash --delete-branch --subject "release vX.Y.Z (#<n>)"
   --body-file .context/release-pr-body.md`. The title is `release vX.Y.Z`; the
   `(#<n>)` suffix is added by hand because `--subject` is used verbatim and the
   history reads `release v0.9.0 (#157)`. The PR description is the squash
   commit body; add no other text or attribution. Never `--admin` and never
   bypass a required check. If the merge is refused, stop and report.
3. `git fetch origin main --tags`. Take the merge commit from `gh pr view <n>
   --json mergeCommit --jq .mergeCommit.oid` and check
   `git show <sha>:lib/coolhand/version.rb` still says `X.Y.Z`.

## Phase 3: Tag

1. `git tag -a vX.Y.Z <merge commit sha> -m "vX.Y.Z"`. Annotated, like the
   existing tags (check with `git cat-file -p v<previous>`). The target is the
   merge commit, not `origin/main` HEAD, in case something merged after it.
2. `git push origin refs/tags/vX.Y.Z`. Push only that ref, never `--tags`.
3. Verify with `git ls-remote --tags origin 'vX.Y.Z*'`. The `git push` output
   can be swallowed by the shell's output filter, so don't trust its silence;
   the `^{}` line must show the merge commit.

Never `rake release` or `gem push`; CI publishes.

## Phase 4: Release notes

1. Fetch the previous release as the format template:
   `gh release view v<previous> --json body --jq .body`. Match its structure
   and tone: `## 🚀 What's New` (one-paragraph summary), then a `---`-separated
   section per theme (`## ✨ New: ...`, `## 🛠️ Fixed: ...`, `## 🔒 Security
   Hardening`, `## ⚠️ Heads-up When Upgrading`, `## 🧹 Other Changes`), then
   `## 📌 Known Follow-ups` and `## 🔗 Resources`. Include only the sections
   that have content, but always keep Heads-up, Known Follow-ups and Resources.
2. Source the content from the `## [X.Y.Z]` CHANGELOG section and the merged
   PRs since the previous tag (`git log v<previous>..vX.Y.Z --oneline`), reading
   the PRs and the diff for anything the changelog compresses. Write for users:
   what it does, a short code example for new API, migration notes for
   anything behavior-affecting. Use full `https://github.com/...` URLs (blob
   links to `main` for docs), not relative links, because the notes render on
   the Releases page.
3. **Verify every claim and every issue link before publishing.** For
   Known Follow-ups, take the list from the previous release and run
   `gh issue view <n> --json state` on each: drop closed ones, and re-read any
   issue the release touches (partly fixed counts as still open, with a
   parenthetical saying what was fixed). Don't describe a behavior you haven't
   read in the code or the PR. A release note that misstates scope is worse
   than a short one.
4. Write the notes to `.context/release-notes-vX.Y.Z.md` (gitignored).
5. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file
   .context/release-notes-vX.Y.Z.md --latest`. Not a draft and not a
   prerelease, same as the previous release. Confirm with
   `gh release view vX.Y.Z --json name,tagName,isDraft,url`.

## Phase 5: Report

State, in the final message:
- The merged PR number, its squash commit, and the tag (which points at it).
- The release URL.
- The Publish workflow run (`gh run list --workflow publish.yml --limit 1`) and
  whether it is waiting on `rubygems-publish` approval. Do not approve it or
  publish by any other route. Check the run again later if the user asks
  whether the gem is live (`gem search coolhand-ruby --remote`, or the
  RubyGems page).

## Rationalizations to resist

- *"The version file on my branch says X.Y.Z, close enough."* Read it from the
  PR head before merging and from the merge commit after. Tagging a stale
  checkout publishes the wrong code.
- *"Checks are probably green, I'll merge."* Run `gh pr checks`. A release
  doesn't ship on a red or pending build.
- *"The default squash message is fine."* The title (`release vX.Y.Z (#n)`) and
  the PR description as the body are the permanent record of the release; set
  both explicitly.
- *"I'll publish the notes first and tag after."* `--verify-tag` exists so a
  release can't point at nothing; GitHub would otherwise create the tag itself
  from the default branch tip, unannotated and unreviewed.
- *"The old Known Follow-ups list is fine, I'll copy it."* Issues get closed
  between releases. Check each one.
- *"`git push` printed nothing, so it probably worked."* Verify with
  `git ls-remote`.
