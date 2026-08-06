# 072 — The Local Build Never Reaches /Applications

**Status: shipped** — `c891b50`. R1 (install step, foreign-bundle and
signing-downgrade guards, atomic swap, launch the installed path) and R3
(post-install version/mtime echo) as written. §B landed as a variant of the
recommendation: `MARKETING_VERSION` pinned to `0.0.0`, and the git-derived build
number applied to `release.sh` only — local builds keep the project's pinned
number. Open question 1 answered: `release.sh` stays distribution-only.
Open question 2 answered: refuse the Developer ID → ad-hoc downgrade unless
`FORCE_INSTALL=1`.

> `run-local.command` builds a Release app and launches it **from the build
> directory**. Nothing in the repo ever writes to `/Applications`. So the copy the
> user actually double-clicks from the Dock is whatever was hand-dragged there
> once, and it silently rots — which is what "the carousel detail page ignores my
> arrow keys" really was.

## Current state (verified)

- `scripts/run-local.command:41-42` — `OUTPUT_DIR=build/local-release`,
  `APP_PATH=$OUTPUT_DIR/Build/Products/Release/AtelierRefs.app`. Step 4
  (`launch_app`, `:141-144`) is `open "${APP_PATH}"` — the **build-tree** bundle.
  There is no install step, and no mention of `/Applications` anywhere in
  `scripts/`.
- `scripts/release.sh` ends at a DMG + appcast (`:249-273`). It deliberately does
  not install either — correct for a distribution lane, but it means **no script
  in the repo puts a build where the user launches from.**
- On this machine, right now: `/Applications/AtelierRefs.app` is dated **31 Jul**;
  `build/local-release/.../AtelierRefs.app` is current. Two bundles, same bundle
  id (`sujenphea.AtelierRefs`), same sandbox container — so they share a library
  and are indistinguishable once running.
- **Both read `CFBundleShortVersionString = 1.0`, `CFBundleVersion = 1`.** Nothing
  bumps the build number, so:
  - the user cannot tell which bundle a running app came from;
  - LaunchServices has no version signal to prefer one registration over the other;
  - Sparkle's appcast (A3) would consider every build identical.
- `quit_running_instance` (`:128-138`) quits by bundle id, so a stale
  `/Applications` copy that is running *does* get quit — and then `open` launches
  the build-tree copy. The Dock icon still points at the stale one.

### The downstream symptom the user actually reported

"Arrow keys / buttons on the carousel item detail don't work in the
`/Applications` app." That is [069]'s `DetailKeyCatcher`
(`ItemDetailView.swift:1424-1522`) — the NSView that borrows first responder so ←/→
reach the pager instead of the grid behind the overlay. It is present in the
working tree and absent from a 31 Jul bundle. **Not a detail-page bug; a stale
binary.** (The genuine carousel gaps in the detail page are [078]; the genuine
arrow-key gap in the *grid* is none — the grid's map is `MasonryGridHost.swift:1776`.)

## The fix

### A — an install step (the whole issue)

`run-local.command` grows Step 5, `install_app`, after `build_app` and before
launch:

1. Refuse if `/Applications/AtelierRefs.app` is **not** ours — compare
   `CFBundleIdentifier`, not the name. A foreign bundle at that path is a stop,
   not an overwrite.
2. `quit_running_instance` first (already exists, `:128`) — replacing a running
   bundle's contents under it is how you get a half-swapped app.
3. Replace atomically: `ditto` into a sibling temp dir, then
   `mv`-swap + delete the old, rather than `rm -rf` then copy (a failed copy after
   an `rm` leaves the user with no app at all).
4. Re-register with LaunchServices (`lsregister -f`) so the Dock/Spotlight entry
   points at the new bundle.
5. `open` the **installed** path, not the build path.

Gate it: `INSTALL=0` skips (keeps today's build-tree behaviour for a quick
throwaway run), `INSTALL_DIR` overrides `/Applications`. Default is install —
that is what the script is for.

Ad-hoc signing is unchanged; a `/Applications` bundle signed `-` runs fine
locally, it simply isn't distributable (already stated at `:86`).

### B — a build number that moves

`CURRENT_PROJECT_VERSION` is hand-pinned at 1. Derive it in both scripts from
`git rev-list --count HEAD` (monotonic, no state file, no commit churn) and pass
it on the `xcodebuild` line — `release.sh` already threads
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` through (`:136-137`), so this is one
`resolve_version` change shared by both lanes. Surface `version (build)` in
Settings ▸ About so "which build am I looking at" is answerable without Finder.

Sequencing note: this must land **before** Sparkle's appcast goes live, or the
first real update ships against a feed where every entry claims build 1.

### C — the honesty check

`verify-release.sh` gets a sibling assertion, or a line in `run-local`'s summary:
print the installed bundle's version + mtime after installing, so the script's
last line proves what is now at `/Applications`.

## Schema / migration impact

**None.** Build tooling only.

## Phased implementation

1. **R1 (S)** — `install_app` in `run-local.command` + the not-ours guard +
   lsregister + launch-installed. Fixes the reported issue outright.
2. **R2 (S)** — git-derived build number in `resolve_version`, shared by both
   scripts; version string in Settings ▸ About.
3. **R3 (XS)** — post-install version/mtime echo.

## Test strategy

Shell, not XCTest — this is the repo's one bash surface:

- `INSTALL_DIR` pointed at a temp dir: fresh install, replace-existing, replace
  while running, foreign-bundle refusal (a stub `.app` with a different
  `CFBundleIdentifier`), and interrupted-copy leaves the old bundle intact.
- `NO_LAUNCH=1` + `INSTALL=1` composes (install without opening).
- Build-number derivation: shallow clone / detached HEAD still yields a number.

## Effort: **A: S · B: S · C: XS**

## Risks & edge cases

- `/Applications` needs an admin write on some setups — detect `EACCES` and say
  so with the `sudo`/`INSTALL_DIR` escape, rather than failing inside `ditto`.
- Overwriting a bundle that is *also* the Sparkle update target could confuse an
  in-flight update; install should refuse while `Updater.app` is running.
- A user who keeps a signed release build in `/Applications` deliberately will now
  have it stomped by an ad-hoc local build. The summary line (C) is what makes
  that visible; consider refusing to replace a Developer-ID-signed bundle with an
  ad-hoc one unless `FORCE_INSTALL=1`.
- Two bundles sharing one container is the *current* state and is not fixed by
  this — it is fixed by there only being one bundle afterwards.

## Open questions

1. Should `release.sh` also install its (notarized) output locally, or stay
   distribution-only? — recommended: stay distribution-only, add a one-line hint.
2. Refuse-to-downgrade-signing (Developer ID → ad-hoc) by default, or warn only?
3. `git rev-list --count` vs a committed build-number file — recommended: git,
   no state to forget to bump.
