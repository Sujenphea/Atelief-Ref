# 081 — Production readiness Phase 2: P1 hardening (G6–G10)

Closes the five hardening gaps from
[021](../.docs/021-production-readiness-plan.md) Phase 2.

## Summary

- **G6** — Capture token moved to Keychain (`CaptureTokenStore`); migrates and
  deletes any legacy UserDefaults value on first read.
- **G7** — Canvas disk thumbnails load via `imageFileURL` + `DecodeScheduler`
  off-main (file read + decode leave the sync path). In-memory fixtures still use
  `imageData`. Manual Instruments confirmation remains a Phase 3 gate.
- **G8** — `RemoteImageFetcher` streams with `session.bytes(from:)` and aborts at
  the 32 MB cap (also rejects oversized `Content-Length` early).
- **G9** — `pauseStaleOpenJobs` / `reconcileOrphanedKnownItems` do check+mutate in
  one `write` transaction (no read-then-write TOCTOU window).
- **G10** — `.persistenceFailure(detail:)` carries SQLite code/message;
  `refreshSweeps` no longer swallows `jobItemCounts` into fake-healthy `[:]`.

## Files changed

- App: `CaptureTokenStore.swift`, `IngestionModel.swift`, `CanvasContent.swift`
- Core: `AtelierError.swift`, `AppServices.swift` + invariant tests
- Ingestion: `RemoteImageFetcher.swift` + tests
- Canvas: `TileImageSource.swift`, `DecodeScheduler.swift`, `CanvasEngine.swift`

## Migration notes

Existing installs: first launch after upgrade migrates the capture token from
UserDefaults into Keychain and removes the plist key. Extension auth is unchanged
(same token value).
