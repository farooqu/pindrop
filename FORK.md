# Fork Workflow (farooqu/pindrop)

This repository is a fork of [watzon/pindrop](https://github.com/watzon/pindrop).
The fork's `main` is the build that Umer runs day to day. Upstream remains the
home for generally useful fixes, so changes are written so they can be sent
upstream whenever that makes sense.

This file is fork-only. Never include it, `.agents/`, or the fork section of
`AGENTS.md` in an upstream pull request.

## Remotes and branches

| Name | Points to | Purpose |
| --- | --- | --- |
| `origin` | `farooqu/pindrop` | The fork. All pushes go here. |
| `upstream` | `watzon/pindrop` | Fetch-only (push URL is `DISABLED`). |
| `main` | `origin/main` | Consumable build: `upstream/main` + fork-only commits + integrated contributions. |
| `fix/*`, `feat/*`, `perf/*`, `docs/*`, … | based on `upstream/main` | **Upstream-bound** contributions. One concern per branch. |
| `fork/*` | based on `origin/main` | **Fork-only** changes that should never go upstream. |

`.agents/setup` configures these remotes in Amp orbs. On another machine, run:

```bash
git remote add upstream https://github.com/watzon/pindrop.git
git remote set-url --push upstream DISABLED
git config rerere.enabled true
gh repo set-default farooqu/pindrop
```

## Decide first: upstream-bound or fork-only?

Default to **upstream-bound**. A change is fork-only only when it is specific to
this fork, for example orb setup, fork docs, personal defaults, or a behavior
upstream has explicitly declined.

Keep upstream-bound changes upstreamable:

- Branch from `upstream/main`, not `main`. This keeps fork-only commits out.
- Follow `AGENTS.md` conventions exactly: code style, `just` recipes,
  localization pipeline, Swift Testing, and minimal diffs.
- Keep one focused concern per branch. Use Conventional Commits, for example
  `fix(speech): …` or `feat(notes): …`, matching upstream history.
- Don't reference fork-only files, Amp, orbs, or this workflow in code, commits,
  or PR text.

Keep fork-only changes cheap to carry:

- Prefer new fork-only files over edits to upstream files. Every edited upstream
  line is a potential conflict on each sync.
- If an upstream file must change, keep the edit small and isolated, then record
  it in the ledger below.

## Workflows

### Sync upstream into `main`

`main` is published and consumed, so **merge** upstream changes. Don't rebase
`main` or force-push it.

```bash
git fetch upstream origin
git switch main && git pull --ff-only origin main
git merge --no-edit upstream/main   # resolve conflicts; see below
git push origin main
```

Conflict rules:

- Upstream merged our contribution with edits or a squash: take upstream's
  version (`git checkout --theirs <file>` for those hunks). Then update the
  ledger.
- A fork-only edit conflicts with an upstream change: keep upstream's change
  and reapply the smallest fork edit.
- `rerere` records resolutions, so repeated conflicts resolve automatically.

### Contribute a fix or feature (upstream-bound)

```bash
git fetch upstream
git switch -c fix/<topic> upstream/main
# implement + verify (see Verification)
git push -u origin fix/<topic>

# 1) Upstream PR (explicit repo; gh defaults to the fork)
gh pr create --repo watzon/pindrop --base main --head farooqu:fix/<topic> \
  --title "fix(<scope>): <summary>" --body "<why + what + how verified>"

# 2) Integrate into the fork's main so we can use it now. The integration
#    branch carries the ledger update, so the contribution branch stays clean.
git switch -c fork/integrate-<topic> origin/main
git merge --no-ff --no-edit fix/<topic>
# edit the FORK.md ledger row, then commit it
git push -u origin fork/integrate-<topic>
gh pr create --repo farooqu/pindrop --base main --head fork/integrate-<topic> \
  --title "Integrate fix/<topic> (upstream watzon/pindrop#<n>)" --body "Upstream PR: watzon/pindrop#<n>"
gh pr merge --repo farooqu/pindrop --merge --delete-branch <fork-pr>   # merge commit, never squash
```

Use merge commits, not squash, when integrating into `main`. The original
commits then match the upstream PR, so later upstream syncs merge cleanly.

### Keep a contribution current

When upstream moves, or a reviewer asks for changes:

```bash
git fetch upstream
git switch fix/<topic>
git rebase upstream/main
git push --force-with-lease origin fix/<topic>   # contribution branches only
```

If the branch changed meaningfully, merge it into `main` again through another
fork PR.

### After upstream merges or closes a PR

- **Merged:** sync upstream into `main`, delete the branch
  (`git push origin --delete fix/<topic>`), and remove it from the ledger.
- **Closed or stale, still needed:** keep it in `main`, then mark it
  "carried" in the ledger. Resubmit later if useful.

### Fork-only change

```bash
git switch -c fork/<topic> origin/main
# change, verify, push
gh pr create --repo farooqu/pindrop --base main --head fork/<topic>
```

## Ship (Amp)

The Amp project `ufarooq/pindrop` uses a **custom Ship** prompt that tells the
agent to follow this section. Amp's default "merge to main" would push thread
changes straight onto `main`. That would skip the upstream PR and mix
upstreamable work with fork-only files. When a thread is shipped:

1. **Classify** each change as upstream-bound or fork-only (see "Decide
   first"). Split mixed work into separate branches. Fork-only files (`FORK.md`,
   `.agents/`, the `AGENTS.md` fork section) are always fork-only.
2. **Place the commits on the right base.** Orb threads start on `main`, so
   move the thread's commits to a new branch. Use `fix/<topic>` or
   `feat/<topic>` on `upstream/main` (cherry-pick), or `fork/<topic>` on
   `origin/main`. Use Conventional Commit messages. Don't push thread work
   straight to `main`. Upstream syncs are the only direct pushes.
3. **Verify** as described under Verification: run the Swift parse check and
   the l10n lint, push the branch, then watch macOS CI. If CI fails, fix it and
   push again. If Actions is off or CI can't run, stop and report that the
   change is unverified. Don't merge unverified Swift changes into `main`.
4. **Open PRs.**
   - Upstream-bound: open the upstream PR with `--repo watzon/pindrop --head
     farooqu:<branch>`, or update the existing one. The body covers why, what,
     and how it was verified, with no Amp or fork references. Then integrate it
     through `fork/integrate-<topic>` with the ledger update, and merge that
     with a merge commit after CI passes.
   - Fork-only: open a PR to `farooqu/pindrop`, and merge it with a merge
     commit after CI passes. Update the ledger in the same PR when `main`'s
     divergence changes.
5. **Report** the branch names, PR links, CI run links, and anything left
   unverified or waiting on upstream.

## Verification

Orbs are Linux. Xcode, `xcodebuild`, and most of the Swift package (SwiftData,
AVFoundation, `os`) can't build there.

- **In an orb:** syntax-check the changed Swift files with the Linux toolchain
  that `.agents/setup` installs. Files are checked one at a time because the
  repo reuses some file names:
  `git diff --name-only --diff-filter=d upstream/main... -- '*.swift' | xargs -rn1 swiftc -parse`.
  For string changes, run `just l10n-sync` and `just l10n-lint`. Parsing catches
  syntax errors only, not type errors.
- **Authoritative:** push the branch to `origin`. `.github/workflows/ci.yml` runs
  on every branch push on macOS: shared package tests, iOS shared build, unsigned
  app build, and unit tests. Watch it with
  `gh run watch --repo farooqu/pindrop $(gh run list --repo farooqu/pindrop --branch <branch> --limit 1 --json databaseId -q '.[0].databaseId')`.
  GitHub Actions must be enabled on the fork (Actions tab → enable workflows).
- **On a Mac:** `just build` and `just test`, or run an Amp thread on a local
  Mac runner.

Don't call a Swift change verified until macOS CI or a Mac build and test run
passes.

## Consuming `main`: fork releases and auto-updates

Your Macs run fork releases published as GitHub releases on `farooqu/pindrop`.
Each release is signed with your own code-signing certificate, which costs
nothing. Sparkle installs updates from the fork's
`releases/latest/download/appcast.xml`.

The work is split by machine. The release Mac (ITSO-WX2745, Amp runner
`macbook`, checkout `~/personal/pindrop`) builds and signs; it has no `gh`. An
orb, which has `gh`, publishes the release.

### One-time setup (on the Mac that builds releases)

1. **Code-signing certificate.** Run `just fork-signing-cert`. It generates a
   self-signed `Pindrop Fork` code-signing certificate on your Mac, imports it
   into your login Keychain with `codesign` access, and trusts it for code
   signing; macOS asks for your password. Build all releases with this one
   certificate so macOS keeps microphone and accessibility permissions across
   updates.
2. **Sparkle EdDSA key.** Run `just fork-sparkle-key`. It downloads Sparkle's
   tools, creates the key on first run, and prints the public key. The private
   key stays in your login Keychain. Put the public key in `SUPublicEDKey` in
   `Pindrop/Info.plist` and merge that through a `fork/…` branch.
   `just fork-build` refuses to run while that value is still upstream's key.
3. **Tools:** `brew install just create-dmg`.

To release from a second Mac, copy both private keys once. iCloud Keychain
only syncs items marked as synchronizable, and `security import` and
`codesign` use the login keychain, so don't rely on it to share the identity.

- **Certificate:** in Keychain Access → login → My Certificates, export
  `Pindrop Fork` as a `.p12` with a password. On the other Mac, run
  `security import Pindrop-Fork.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`.
  Then open the certificate in Keychain Access → Trust and set Code Signing to
  Always Trust.
- **Sparkle key:** run `./bin/generate_keys -x sparkle-key.txt` on the first
  Mac, then `./bin/generate_keys -f sparkle-key.txt` on the other.
- Delete both export files afterwards. Store them only in a password manager.

### Publish a release

**1. On the Mac** (an Amp thread on runner `macbook`, or by hand):

```bash
cd ~/personal/pindrop
git switch main && git pull --ff-only
just fork-build "Pindrop Fork"
```

`fork-build` (in `fork.just`, imported at the end of `justfile`) runs these
steps:

1. Checks that you're on a clean `main` that matches `origin/main`, the feed
   and key point at the fork, and the certificate exists.
2. Runs `just test-unsigned`.
3. Builds Release, using the commit count of `main` as the build number.
4. Signs the app with the certificate.
5. Creates `dist/Pindrop.dmg`.
6. Writes an EdDSA-signed `dist/appcast.xml` pointing at the tag
   `v<upstream version>-fork.<build>`.
7. Records the tag, version, build, commit, and DMG checksum in
   `dist/fork-release.env`.

**2. In an orb:** copy the three `dist/` files from the Mac thread into the
orb checkout's `dist/` with `download_thread_file`, then run `just
fork-publish`. It does the following:

1. Verifies the DMG checksum and that the appcast matches the tag and build.
2. Checks that the commit is on `origin/main` and the release doesn't exist
   yet.
3. Creates the GitHub release as Latest, with the tag created at that commit.

The release keeps upstream's marketing version and changes nothing in the Xcode
project, so upstream merges stay conflict-free. The build number only grows
because `main` is never rewritten.

### Install on each Mac

- First install: download the DMG from the fork's latest release. macOS blocks
  it once because it isn't notarized. Allow it under System Settings → Privacy
  & Security → Open Anyway, or run
  `xattr -dr com.apple.quarantine /Applications/Pindrop.app`. Then grant
  microphone and accessibility access.
- After that, Sparkle offers new fork releases automatically. Upstream releases
  aren't offered, because the feed and signing key are the fork's.

### Local development builds

`just build` uses upstream's `DEVELOPMENT_TEAM`. Select your own team in Xcode
for local builds, and don't commit that change.

## Divergence ledger

Keep this ledger current in the same PR that changes `main`'s divergence from
`upstream/main`.

| Item | Kind | Upstream status | In `main`? |
| --- | --- | --- | --- |
| `FORK.md`, `.agents/setup`, `.agents/resume`, `.gitignore` exceptions, `AGENTS.md` fork section | fork-only | n/a | yes |
| Fork releases: `fork.just`, `import? 'fork.just'` at the end of `justfile`, `SUFeedURL` and `SUPublicEDKey` in `Pindrop/Info.plist` | fork-only | n/a | yes |
| `fix/parakeet-cache-path` (load Parakeet from Pindrop's model cache) | contribution | [watzon/pindrop#87](https://github.com/watzon/pindrop/pull/87) open; conflicts with upstream's move of `ModelManager` into `Packages/PindropShared`, so it needs a rebase | no |
