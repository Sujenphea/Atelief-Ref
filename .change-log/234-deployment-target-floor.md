# 234 — Deployment-target floor: 26.5 → 26.0

## Summary

First step of the distribution track (`.docs/052`, phase **A0**). Lowered the app's
`MACOSX_DEPLOYMENT_TARGET` from the accidental `26.5` placeholder to **`26.0`**, so any
macOS 26.x point release (26.0–26.4) can install the app — previously the floor excluded
everyone not on the very latest point release.

### Audit notes
- The app has **no `@available` / `#available(macOS …)` gates** and no detected
  macOS-26-only API calls; all four SPM packages already target `.macOS(.v14)`.
- Dropping to `26.0` is same-major and therefore zero-risk (no weak-linked-symbol runtime
  hazard, no visual change — the Liquid Glass toolbar chrome is unchanged within macOS 26).
- Reaching further back (macOS 15 / 14) was **deliberately deferred**: with no
  `#available` guards, any unconditional 26-only symbol would compile but crash at runtime
  on older OS, so it needs a real build-and-run pass on that OS plus a decision about
  Liquid Glass degradation — tracked as a separate sub-task, not bundled here.

## Files changed

- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — `MACOSX_DEPLOYMENT_TARGET`
  `26.5 → 26.0` on all four config blocks (project Debug/Release + test-target
  Debug/Release; lines 347/405/489/510).
- `AtelierRefs/AtelierRefsTests/ConfigContractTests.swift` — **new.** 12A config-guard
  test asserting the shipped `LSMinimumSystemVersion` never regresses above the agreed
  floor (`[26, 0]`). Home for the forthcoming Sparkle plist-key guards (A3/A4).

## Verification

- `xcodebuild build … CODE_SIGNING_ALLOWED=NO` — clean at 26.0.
- Built app `Contents/Info.plist` `LSMinimumSystemVersion` = `26.0`.
- `xcodebuild test -only-testing:AtelierRefsTests/DeploymentTargetContractTests` — passed.

## Migration notes

None. Lowering the deployment floor is backward-compatible for existing installs. The new
guard test fails if the target is ever raised above `26.0`; that ceiling lives in
`DeploymentTargetContractTests.floor` and should only change as a reviewed decision.
