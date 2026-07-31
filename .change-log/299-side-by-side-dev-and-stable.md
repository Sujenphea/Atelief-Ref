# 299 — side-by-side dev and stable

## Summary

The app was only ever runnable from Xcode. Using it for real meant either not
touching the code or accepting that the running app changes under you — and both
builds opened the SAME library, because a sandbox container is keyed by bundle id
and Debug and Release shared one.

That sharing is the dangerous half. `Migrator` is forward-only and deliberately
does not set `eraseDatabaseOnSchemaChange`, and GRDB's `migrate()` does not reject
a database migrated PAST what it knows — `hasSchemaChanges` detects that case, but
`migrate()` only applies what is missing and returns. So a dev build registering a
new migration would migrate the real library in place, and a stable build compiled
before it would then fail at runtime on renamed or dropped columns, silently, with
no downgrade path.

Debug now has its own bundle id, so it gets its own container and its own library.

## 1. Debug is a different app

`PRODUCT_BUNDLE_IDENTIFIER` is `sujenphea.AtelierRefs.dev` on the app target's
**Debug** configuration only; Release still ships `sujenphea.AtelierRefs`. Debug
also sets `INFOPLIST_KEY_CFBundleDisplayName = "AtelierRefs Dev"` so the two are
distinguishable in the Dock and the app switcher.

Release is untouched, so signing and the notarization lane are unaffected. The
entitlements already interpolate `$(PRODUCT_BUNDLE_IDENTIFIER)` for Sparkle's
`-spks`/`-spki` mach-lookup names, so those follow automatically. Debug uses
automatic `Apple Development` signing, and the new id provisioned itself with no
portal work — verified by a clean Debug build whose `CodeSign` step succeeded.

`TEST_HOST` and `TEST_TARGET_NAME` key off product paths and target names, not the
bundle id, so both test targets were unaffected. No test asserts the identifier.

## 2. One hardcoded port, two apps

`CaptureServer.defaultPort` (47321) is fixed because the extension hard-codes it.
With two installable builds that becomes a race: both bind the same port, whichever
launched first wins, and the loser's endpoint is dead — announced only through the
`port … is in use` notice. Observed in practice as
`SocketError. Bind(48): Address already in use`.

The shipping bundle must keep 47321 (the extension's value), so the DEV build
offsets. `IngestionModel.capturePort(bundleID:)` returns `defaultPort + 1` for a
`.dev` bundle id and `defaultPort` otherwise. The port is now passed to the
`CaptureServer` initializer, which previously fell through to its own default —
the reason `capturePort` existed as a display-only value while the server ignored
it.

Verified with both apps running at once: 47321 held by `/Applications`, 47322 by
the DerivedData Debug build, both endpoints live.

Note this is a *bundle id* test, not a build-configuration test. A Debug build that
somehow shipped the production id would take 47321, which is the correct behaviour —
the id is what decides which container and which library are in play.

## Files changed

- `AtelierRefs.xcodeproj/project.pbxproj` — Debug-only `PRODUCT_BUNDLE_IDENTIFIER`
  + `INFOPLIST_KEY_CFBundleDisplayName`.
- `IngestionModel.swift` — `capturePort(bundleID:)`; `capturePort` derived from it;
  `port:` passed to `CaptureServer.init`.

## Migration notes

**The dev library starts empty.** The first Debug run after this change creates a
fresh container at `~/Library/Containers/sujenphea.AtelierRefs.dev/`. The real
library — `Application Support/ref-atelier/`, 768 MB — stays in
`sujenphea.AtelierRefs/` and is now reachable only by a Release build. Copy that
directory across if you want to develop against real data.

**Console filtering is now off by one.** `Diagnostics.swift` hard-codes the
subsystem as the literal `"sujenphea.AtelierRefs"`, and `CaptureServer` restates
it. 291 chose that value precisely *because* it was the bundle id; for a dev build
it no longer is. Arguably a feature — one filter covers both apps — but it is no
longer the property 291 described.

**Both apps declare the same exported UTIs** (`com.ref-atelier.asset-ids`,
`-collection-id`, `-space-id`). Drags are in-app, so this is expected to be
harmless; noted in case a drop ever behaves oddly with both installed.

## Not fixed here

18 test files under `AtelierRefsTests` create SQLite fixtures via
`NSTemporaryDirectory()` and never delete them. Because `TEST_HOST` is the app,
these land in the app's sandbox container, which macOS never purges — 61,261 files
and 13.0 GB had accumulated, against a 768 MB library. Cleared manually; the leak
itself is unfixed. `SQLiteFileSet` already models the `.sqlite`/`-shm`/`-wal`
triple and is the natural basis for a `defer` in each fixture factory.
