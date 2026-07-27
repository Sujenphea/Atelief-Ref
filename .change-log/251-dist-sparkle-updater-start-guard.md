# 251 — Sparkle updater start guard (fix "failed to start")

A3 shipped `SUFeedURL` / `SUPublicEDKey` as deliberate `REPLACE…` placeholders
(the real values come from `generate_keys` + a hosting decision). But
`SparkleUpdater` booted the updater unconditionally (`startingUpdater: true`), so
Sparkle's `startUpdater:` validated the placeholder `SUPublicEDKey`, rejected it
as an invalid Ed25519 key, and the standard user driver raised **"The updater
failed to start."** on *every* launch — including local Debug runs.

## Fix

`UpdaterController` now starts the updater only when the build carries a usable
configuration: `startingUpdater: Self.hasUsableUpdateConfiguration`. With
placeholders present the updater stays unstarted (silent, and the
"Check for Updates…" menu item stays disabled via the `canCheckForUpdates`
bridge); a real Developer ID release with valid keys starts and behaves normally.

`hasUsableUpdateConfiguration` is split into a pure overload
`hasUsableUpdateConfiguration(feedURL:publicEDKey:)` for testability: both values
must be present, non-empty, free of the `REPLACE` marker, and the key must decode
to a 32-byte (Ed25519) Base64 blob — so a malformed paste can't reproduce the
alert either.

## Files changed

- **Modified**: `AtelierRefs/AtelierRefs/SparkleUpdater.swift`.
- **New**: `AtelierRefs/AtelierRefsTests/SparkleUpdaterConfigTests.swift` (5 tests:
  real config, the exact shipped placeholders, placeholder-in-either-field,
  missing/empty fields, malformed/wrong-length key).

## Migration notes

- No behaviour change for a properly configured release. To enable auto-update:
  run `generate_keys`, paste the public key into `Info.plist` `SUPublicEDKey`, set
  a real `SUFeedURL`, rebuild (see SECRETS.md).
- Still un-verified downstream (separate from this fix): the sandboxed Installer
  XPC-service mach-name matching under the SPM binary framework — only testable in
  a signed build against a staging appcast.
