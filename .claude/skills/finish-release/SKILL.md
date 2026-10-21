---
name: finish-release
description: |
  Finishes a release once its release-prep PR (from /prep-release) has been
  merged: creates and pushes the annotated vX.Y.Z tag on main, then publishes
  the GitHub release notes in the same format as the previous release. Pushing
  the tag triggers the Publish workflow (RubyGems Trusted Publishing), so this
  is the step that ships the gem. Use when the user types /finish-release,
  asks to "tag the release", "publish the release notes", "ship v0.x.y", or
  has just merged the release-prep PR.
---

# Finish Release

The counterpart to `/prep-release`. That skill stops at an open release PR and
never tags or publishes; this one starts after the user has reviewed and merged
that PR. Running it is the user's go-ahead to tag and publish. Two steps, in
this order: **tag, then release notes**. The release is created with
`--verify-tag`, so the tag has to exist first.

**What pushing the tag does:** `.github/workflows/publish.yml` runs on any
`v*.*.*` tag push. It runs the specs and RuboCop, checks the tag matches
`Coolhand::VERSION`, then publishes to RubyGems behind the `rubygems-publish`
environment, which may wait for a human approval. Say so in the final report.

## Phase 1: Preconditions (abort on any failure, change nothing)

1. `git fetch origin main --tags`.
2. Read the version from `origin/main`, not from the working tree:
   `git show origin/main:lib/coolhand/version.rb`. Call it `X.Y.Z`; the tag is
   `vX.Y.Z`.
3. Check all of these, and stop and tell the user which one failed:
   - `X.Y.Z` is greater than the latest tag (`git describe --tags --abbrev=0
     origin/main`). If equal, the release PR has not merged yet (or the version
     was never bumped).
   - `git show origin/main:CHANGELOG.md` has a `## [X.Y.Z]` heading.
   - The tag does not already exist, locally (`git tag -l vX.Y.Z`) or on the
     remote (`git ls-remote --tags origin 'vX.Y.Z*'`), and no release exists
     (`gh release view vX.Y.Z` fails). If the tag exists but the release does
     not, skip Phase 2 and resume at Phase 3, after confirming the tag points at
     the commit that set the version.
   - The release-prep PR is merged: `gh pr list --state merged --search
     "release vX.Y.Z" --json number,mergeCommit`. Note its merge commit.
4. The tag target is `origin/main` HEAD, and it must contain the version bump
   (it does if step 2 passed). Do not tag a local branch or a stale checkout.

## Phase 2: Tag

1. `git tag -a vX.Y.Z <sha of origin/main> -m "vX.Y.Z"`. Annotated, like the
   existing tags (check with `git cat-file -p v<previous>`).
2. `git push origin refs/tags/vX.Y.Z`. Push only that ref, never `--tags`.
3. Verify with `git ls-remote --tags origin 'vX.Y.Z*'`. The `git push` output
   can be swallowed by the shell's output filter, so don't trust its silence;
   the `^{}` line must show the intended commit.

Never `rake release` or `gem push`; CI publishes.

## Phase 3: Release notes

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

## Phase 4: Report

State, in the final message:
- The tag and the commit it points at.
- The release URL.
- The Publish workflow run (`gh run list --workflow publish.yml --limit 1`) and
  whether it is waiting on `rubygems-publish` approval. Do not approve it or
  publish by any other route. Check the run again later if the user asks
  whether the gem is live (`gem search coolhand-ruby --remote`, or the
  RubyGems page).

## Rationalizations to resist

- *"The version file on my branch says X.Y.Z, close enough."* Read it from
  `origin/main`. Tagging a stale checkout publishes the wrong code.
- *"I'll publish the notes first and tag after."* `--verify-tag` exists so a
  release can't point at nothing; GitHub would otherwise create the tag itself
  from the default branch tip, unannotated and unreviewed.
- *"The old Known Follow-ups list is fine, I'll copy it."* Issues get closed
  between releases. Check each one.
- *"`git push` printed nothing, so it probably worked."* Verify with
  `git ls-remote`.
