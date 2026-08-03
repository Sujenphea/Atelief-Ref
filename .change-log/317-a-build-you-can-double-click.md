# 317 — A build you can double-click

## Summary

`scripts/run-local.command` — build the Release configuration and launch it, from a
double-click in Finder.

This is the gap `release.sh` leaves on purpose. That script is the *distribution* lane:
it preflights a Developer ID identity and an `AtelierRefs-notary` keychain profile and
exits non-zero without them, because a release that isn't signed and notarized isn't a
release. Correct for shipping, useless for the far more common question — *what does the
production configuration actually feel like on this machine, right now.*

Nothing served that. `⌘R` in Xcode gives you Debug; the Release configuration was only
reachable by hand-assembling an `xcodebuild` invocation that works around its own signing
settings.

## What it does

```
resolve signing identity -> xcodebuild (Release) -> quit old instance -> open
```

Same configuration, same hardened runtime, same entitlement set as the release lane. Only
the signing identity differs, and only when it has to.

**Signing degrades, it doesn't fail.** `Release.xcconfig` pins
`CODE_SIGN_IDENTITY = "Developer ID Application"` with `CODE_SIGN_STYLE = Manual`. On a
provisioned release machine that is exactly right, and the script leaves it alone —
detects the identity, passes no overrides, builds signed. Everywhere else that pin is a
hard build failure, so it falls back to ad-hoc (`-`): the app still gets the hardened
runtime and every entitlement, it simply isn't distributable. `DEVELOPMENT_TEAM` is
cleared alongside it, because a team ID next to an ad-hoc identity sends `xcodebuild`
hunting a provisioning profile that doesn't exist. `FORCE_ADHOC=1` takes the fallback
even on a provisioned machine.

**It quits the old instance first.** `open` on a running app just brings it forward — you
would be looking at the build you just replaced, wondering where your fix went. Note this
also quits an Xcode Debug session: same bundle id, and only one can be frontmost.

**It addresses that instance by bundle id**, via `osascript -e 'quit app id …'` — never a
`pkill` on the name. Every path in this repo contains the string `AtelierRefs`; a pattern
kill would take unrelated processes with it.

**The Terminal window survives a failure.** An `EXIT` trap holds it open on a non-zero
exit, so the error is legible rather than a window that blinks out of existence under the
default Terminal profile.

## Choices worth keeping

- **`.command`, not `.sh`** — the extension is the entire feature. Finder runs a
  `.command` in Terminal on double-click; a `.sh` opens in an editor. It is an ordinary
  bash script otherwise and runs fine from a shell.
- **Paths resolve from `BASH_SOURCE`** — Finder launches a `.command` with the working
  directory set to `$HOME`, not the repo. Anything relative would silently target the
  wrong tree.
- **Its own derived-data path** (`build/local-release`) — so it never fights Xcode's build
  folder and never clobbers `build/release`, where `release.sh` puts the real artifact.
  Incremental across runs; delete the directory for a clean build.

## Files changed

- `scripts/run-local.command` — new, executable

## Notes

Environment overrides: `SCHEME`, `CONFIGURATION`, `OUTPUT_DIR`, `FORCE_ADHOC=1`,
`NO_LAUNCH=1` (build without launching).

No migration — additive, nothing else references it. The build lane itself is unchanged:
this only assembles an `xcodebuild` invocation you could always have typed.

**An ad-hoc build is not a release build in two ways that will bite.** Sparkle's *Check
for Updates* fails against the placeholder `SUFeedURL` in `AtelierRefs/Info.plist`
(`REPLACE-ME.example.com` — still an open decision, see `.docs/052-distribution-export-plan.md`).
And ad-hoc signing carries no team identifier, so Keychain items written by an
identity-signed build — the loopback capture token, `SECRETS.md` — may not be readable;
expect to re-pair the extension. The sandbox container is keyed on the bundle id, which
doesn't change, so the library itself is untouched.
