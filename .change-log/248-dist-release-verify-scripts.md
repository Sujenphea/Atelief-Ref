# 248 — Release + verify scripts

## Summary

Distribution track (`.docs/052`, phase **A2**). Added the two shell scripts that
drive and guard a Developer ID release, both `set -euo pipefail`, one bash
function per step, in the "explicit over clever, stock tools only" style of
decision **6A** (matching the existing `scripts/package-extension.sh`).

- `scripts/release.sh` — the full release lane: resolve version → `xcodebuild
  archive` → `xcodebuild -exportArchive` (developer-id, feeding
  `AtelierRefs/Config/ExportOptions.plist`) → `notarytool submit --wait` →
  `stapler staple` → `create-dmg` → Sparkle `generate_appcast`.
- `scripts/verify-release.sh` — the **9A** artifact guard: `codesign
  --verify --deep --strict`, `spctl` Gatekeeper assessment, `stapler validate`,
  notarization-ticket presence, hardened runtime + app-sandbox + network.server
  entitlements, and (guarded) the Sparkle `sign_update` DMG signature. Each check
  is its own function with a PASS/FAIL line; any failure exits non-zero, and a
  summary prints N passed / which failed.

No secrets are embedded — the Developer ID identity, the `AtelierRefs-notary`
notarytool profile, and (later) the Sparkle EdDSA key are all read from the login
Keychain per `SECRETS.md`. Defaults for team ID / scheme / paths come from the
committed `Release.xcconfig` / `ExportOptions.plist`; everything is overridable
via env vars.

## Files changed

- `scripts/release.sh` — **new, executable.** Overridable CONFIG block
  (`PROJECT`, `SCHEME=AtelierRefs`, `CONFIGURATION=Release`, `APP_NAME`,
  `TEAM_ID=L25247V6JG`, `NOTARY_PROFILE=AtelierRefs-notary`,
  `EXPORT_OPTIONS_PLIST`, `OUTPUT_DIR=build/release`, `SPARKLE_BIN_DIR`).
  `resolve_version` reads `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` from the
  env or `xcodebuild -showBuildSettings` (the project uses
  `GENERATE_INFOPLIST_FILE`, so those settings are the source of truth).
  `preflight` fails loudly if `xcodebuild`, the Developer ID identity, the
  notarytool profile, or the ExportOptions.plist is missing. Notarization zips
  the `.app` with `ditto` (signature-preserving), submits `--wait`, then staples
  the `.app`. `build_dmg` guards for `create-dmg` with a
  `brew install create-dmg` hint. `generate_appcast` is guarded with an explicit
  `TODO(A3)` error documenting the expected `SPARKLE_BIN_DIR`.
- `scripts/verify-release.sh` — **new, executable.** Takes the `.app` (required)
  and `.dmg` (optional) as args. Six checks as above; the Sparkle DMG check
  SKIPs (does not hard-fail the run) when `sign_update` is absent, since it needs
  phase A3. Entitlements are read out of the signed binary via
  `codesign -d --entitlements :-`; hardened runtime via the `runtime` flag in
  `codesign -dvvv`; notarization via `spctl … source=Notarized`.

## Verification

- `bash -n scripts/release.sh` and `bash -n scripts/verify-release.sh` — both
  parse clean.
- `chmod +x` applied; both are `-rwxr-xr-x`.
- Guard/dry-run logic exercised without credentials: `verify-release.sh` with no
  args prints usage and exits 2; with a nonexistent app path errors and exits 2.
- **`shellcheck` not run — not installed on this machine** (`brew` is available;
  install with `brew install shellcheck` to lint). Scripts were written to
  shellcheck-clean conventions (quoted expansions, `${var}` braces, `command -v`
  guards, arrays for accumulated results).
- **The release lane was NOT executed** — this environment has no Developer ID
  cert, notarytool profile, Sparkle key, or `create-dmg`, so it cannot complete
  (expected).

## Discovered project facts (confirmed)

- Scheme + app target: **`AtelierRefs`** — confirmed via
  `xcodebuild -list -project AtelierRefs/AtelierRefs.xcodeproj` (shared schemes
  are for the SPM packages; `AtelierRefs` is the app).
- Product → **`AtelierRefs.app`** (`PRODUCT_NAME = $(TARGET_NAME)`), bundle id
  `sujenphea.AtelierRefs`, `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`
  (pbxproj), versions generated (`GENERATE_INFOPLIST_FILE = YES`).

## Guarded-as-TODO (pending later phases / credentials)

- **Sparkle `generate_appcast` (release.sh)** and **`sign_update` (verify)** —
  phase **A3** adds the Sparkle SPM dependency + EdDSA key. Until then both are
  guarded: release.sh errors with an actionable `TODO(A3)` + expected
  `SPARKLE_BIN_DIR`; verify skips the DMG-signature check.
- **`create-dmg`** — third-party; guarded with a `brew install create-dmg` hint.

## What the user must supply to run a real release

1. **Developer ID Application** cert + private key in the login Keychain
   (`SECRETS.md`).
2. The **`AtelierRefs-notary`** notarytool keychain profile
   (`xcrun notarytool store-credentials`).
3. **`create-dmg`** installed (`brew install create-dmg`).
4. **Sparkle** integrated (phase A3): EdDSA key in the Keychain and
   `SPARKLE_BIN_DIR` pointing at Sparkle's `bin` (or `generate_appcast` /
   `sign_update` on PATH).
5. **Xcode 26** on macOS 26.

## Assumptions / flags

- DMG-notarization is done at the `.app` level (zip → notarize → staple → build
  DMG from the stapled app), which is the standard offline-validating flow. The
  plan lists `notarytool submit` then `stapler staple` then `create-dmg`, matched
  here; the DMG itself is not separately notarized (the app inside it is stapled).
- `create-dmg` window/icon geometry values are cosmetic defaults; adjust to taste.
- `SPARKLE_BIN_DIR`'s exact DerivedData path is documented from Sparkle's known
  layout but cannot be verified until A3 lands the dependency.
