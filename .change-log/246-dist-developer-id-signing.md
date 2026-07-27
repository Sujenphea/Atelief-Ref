# 246 — Developer ID signing config

## Summary

Distribution track (`.docs/052`, phase **A1**). Switched the app target's **Release**
configuration from automatic "Apple Development" to **manual Developer ID Application**
signing, so archives can be exported + notarized for the direct-download / Sparkle
channel (decision **1A**). Debug is untouched — local development keeps automatic
"Apple Development" signing. Sandbox (`ENABLE_APP_SANDBOX`) and Hardened Runtime
(`ENABLE_HARDENED_RUNTIME`) both stay ON, preserving the security posture (**2A**).

The signing settings + the (public) team ID now live in a committed
`Release.xcconfig`, wired as the Release configuration's base configuration, rather
than being buried inline in the pbxproj (**5A**). An `ExportOptions.plist` for phase
A2's `xcodebuild -exportArchive` and a `SECRETS.md` (Keychain locations, never values)
round out the phase.

## Files changed

- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — app target **Release** config
  (`990778912…`): `CODE_SIGN_STYLE` `Automatic → Manual`; added
  `CODE_SIGN_IDENTITY = "Developer ID Application"`; added
  `baseConfigurationReference` → `Config/Release.xcconfig`. Added the matching
  `PBXFileReference` + main-group entry. `DEVELOPMENT_TEAM = L25247V6JG` and
  `ENABLE_HARDENED_RUNTIME = YES` kept. **Debug config, test/UITest targets, the SPM
  package targets, and the deployment target were NOT touched.**
- `AtelierRefs/Config/Release.xcconfig` — **new.** Non-secret: `DEVELOPMENT_TEAM`,
  `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = Developer ID Application`,
  `ENABLE_HARDENED_RUNTIME = YES`. Base configuration of the Release config.
- `AtelierRefs/Config/ExportOptions.plist` — **new.** `method = developer-id`,
  `signingStyle = manual`, `teamID = L25247V6JG`,
  `signingCertificate = Developer ID Application`. No App Store options (Sparkle is
  MAS-incompatible). Consumed by `xcodebuild -exportArchive` in A2.
- `SECRETS.md` (repo root) — **new.** Checklist of Keychain locations for the
  Developer ID cert (login keychain), the `notarytool` profile (`AtelierRefs-notary`),
  and the forthcoming Sparkle EdDSA private key (A3). Locations only — no values.

## Verification

- `xcodebuild -showBuildSettings … CODE_SIGNING_ALLOWED=NO` (Release): resolves
  `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = Developer ID Application`,
  `DEVELOPMENT_TEAM = L25247V6JG`, `ENABLE_HARDENED_RUNTIME = YES`,
  `ENABLE_APP_SANDBOX = YES`, `MACOSX_DEPLOYMENT_TARGET = 26.0` — pbxproj parses and
  the xcconfig is picked up.
- Debug (unchanged): `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = Apple Development`.
- No signed build attempted — there is no Developer ID cert in this environment
  (expected; not a regression).

## Entitlements audit (2A)

`AtelierRefs/AtelierRefs.entitlements` was **not modified**. Present and correct:
`com.apple.security.app-sandbox`, `com.apple.security.network.server`,
`com.apple.security.network.client`.
**Discrepancy flagged:** the file declares `com.apple.security.files.user-selected.read-**write**`,
whereas the plan baseline and this phase expected `…read-only` (the build setting is
`ENABLE_USER_SELECTED_FILES = readonly`). Left as-is per instruction (report, don't
silently change) — needs a decision on which is intended (export writes files, so
read-write may in fact be desired).

## Migration notes

- **Release builds now require the Developer ID Application certificate** in the
  signing machine's login Keychain. Local Debug builds are unaffected.
- Before A2's `scripts/release.sh` can run, the user must provision the credentials
  in `SECRETS.md`: install the Developer ID cert, and create the
  `AtelierRefs-notary` notarytool keychain profile. (Sparkle key is A3.)
- If Xcode reopens the project and does not show the xcconfig as the Release base
  configuration, it is wired in the pbxproj via `baseConfigurationReference`; no
  manual step should be needed.
