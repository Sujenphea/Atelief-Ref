# 338 — The local build reaches /Applications

## Summary

`run-local.command` built a Release app into `build/local-release` and `open`ed it
**from there**. Nothing in the repo has ever written to `/Applications`, so the
bundle behind the Dock icon was whatever was hand-dragged there once — on this
machine, 31 Jul — and it rotted silently. Both bundles carry the same bundle id
and therefore the same sandbox container, so once running they are
indistinguishable, and both reported `1.0 (1)`.

That is the whole of the reported "the carousel detail page ignores my arrow
keys". `DetailKeyCatcher` (the NSView that borrows first responder so ←/→ reach
the pager) landed 3 Aug and is in the working tree; it simply was not in the app
being launched. Not a detail-page bug — a stale binary. [021]

Three changes:

- **`run-local.command` installs.** New Step 4 between the build and the launch:
  copy the bundle we just built into `/Applications` and launch **that**. All of
  the interesting code in it is guards and the swap.
  - *Foreign bundle* — anything already at the path whose `CFBundleIdentifier`
    is not `sujenphea.AtelierRefs` is a stop, not an overwrite. Identity is the
    bundle id; the name proves nothing.
  - *Signing downgrade* — a Developer-ID-signed install (i.e. something
    `release.sh` produced) is not replaced by an ad-hoc local build unless
    `FORCE_INSTALL=1`. Read off `codesign -dvv`'s `Authority=` /
    `TeamIdentifier=` lines; an unreadable or unsigned bundle answers "not
    Developer ID" so a parse failure can never manufacture a refusal.
  - *Quit first, then swap.* `quit_running_instance` already existed but only
    ran on the launch path; it now runs before every install, `NO_LAUNCH` or
    not. Replacing a bundle under a running process is how you get a
    half-swapped app.
  - *Never rm-then-copy.* `ditto` into a hidden sibling **inside** the install
    dir (so the following `mv` is a same-volume rename), `mv` the old bundle
    aside, `mv` the new one into place, then delete the old. If the final move
    fails the old bundle is restored. There is no window in which a failure
    leaves the user with no app.
  - Quarantine xattr cleared and LaunchServices re-registered (`lsregister -f`)
    so the Dock/Spotlight entry points at the new bundle. Both are best-effort —
    neither failing is a reason to fail an otherwise-good install.
  - Unwritable `INSTALL_DIR` is detected up front, with `sudo` and `INSTALL_DIR=`
    named as the two escapes, rather than surfacing as a bare "Operation not
    permitted" from somewhere inside `ditto`.
- **The last lines are evidence.** After installing, the script reads
  `CFBundleShortVersionString`, `CFBundleVersion` and an mtime back **off disk**
  from the installed bundle and prints them with its path. The mtime is the main
  executable's, not the `.app` wrapper's: an incremental build only rewrites
  files inside the wrapper, leaving its own timestamp weeks old, and `ditto`
  faithfully preserves that lie.
- **A build number that moves.** `MARKETING_VERSION` is now `0.0.0` (nothing has
  shipped), and `release.sh` derives `CURRENT_PROJECT_VERSION` from
  `git rev-list --count HEAD` instead of reading the pinned `1` out of the build
  settings. Release lane only — local builds keep the project's pinned number, so
  a local run never invents a build number that was never published.
  `version (build)` now shows in Settings ▸ Diagnostics, so "which build am I
  looking at" is answerable without Finder.

## Environment gates

| Gate | Default | Effect |
| --- | --- | --- |
| `INSTALL` | `1` | `0` skips the install and runs out of the build tree — exactly the old behaviour, summary line included. |
| `INSTALL_DIR` | `/Applications` | Where the app is installed. |
| `FORCE_INSTALL` | `0` | `1` allows replacing a Developer-ID-signed install with an ad-hoc build. |
| `NO_LAUNCH` | `0` | `1` skips `open`. Composes with the above. |

`INSTALL=1 NO_LAUNCH=1` installs without opening (and still quits a running
instance, and still prints the version/mtime proof). `INSTALL=0 NO_LAUNCH=1` is
byte-for-byte the previous build-only behaviour. `FORCE_ADHOC` and the rest are
unchanged.

`CURRENT_PROJECT_VERSION=34 ./scripts/release.sh` still wins over the git count;
with no git, a non-repo checkout, or an empty count, resolution falls back to the
project's build settings rather than failing a release over a version string. A
shallow clone or detached HEAD still yields a number — `--count` counts what is
actually present.

## Sparkle implication

This must land **before** the appcast (A3) goes live. Sparkle orders updates by
`CFBundleVersion`; a feed generated while every build claims `1` has no way to
tell its entries apart, and the first real update would ship against it. With the
git count, `release.sh` produces a monotonic build number with no state file and
no version-bump commits (currently 475).

## Files changed

- `scripts/run-local.command` — `INSTALL` / `INSTALL_DIR` / `INSTALLED_PATH` /
  `FORCE_INSTALL` / `TARGET_PATH` config; `SIGN_ADHOC` recorded by
  `resolve_signing`; new `installed_bundle_id`, `installed_is_developer_id`,
  `install_app`, `report_installed`; `launch_app` opens `TARGET_PATH`; `main`
  sequences install before launch and no longer double-quits.
- `scripts/release.sh` — `resolve_version` derives `CURRENT_PROJECT_VERSION` from
  `git rev-list --count HEAD` when the environment does not supply it; header
  usage block updated, plus a one-line pointer at `run-local.command` for local
  installs. Still distribution-only — it installs nothing.
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — `MARKETING_VERSION`
  `1.0` → `0.0.0` in all four build configurations. `CURRENT_PROJECT_VERSION`
  stays `1` (the release lane overrides it on the `xcodebuild` line).
- `AtelierRefs/AtelierRefs/SettingsView.swift` — a `Version` row in the
  Diagnostics section reading the two Info.plist keys the diagnostics export
  already reports.

## Migration notes

- **An existing hand-dragged `/Applications/AtelierRefs.app` will be replaced**
  the next time `run-local.command` runs. That is the point of the change. It is
  moved aside and deleted only after the new bundle is in place, but it is not
  kept — if you want that 31 Jul bundle, copy it somewhere else first.
- **No data moves.** Both bundles share one bundle id and therefore one sandbox
  container; the library, preferences, capture token and backup bookmarks are
  outside the `.app` and are untouched by an install.
- The installed app will read `0.0.0 (1)` — that is the project's pinned build
  number, not a regression from `1.0 (1)`. Only `release.sh` output carries the
  git-derived build number.
- A Developer-ID-signed install is now refused rather than stomped. If that
  refusal is unwanted, `FORCE_INSTALL=1`; if the old behaviour is wanted for a
  throwaway run, `INSTALL=0`.
- No schema change. Build tooling and one settings row.
