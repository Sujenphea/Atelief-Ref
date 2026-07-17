# 141 — Version handshake, diagnostics, a11y, scale harness (010 · Phase 3)

Quality tier of [010-production-ship](../.docs/feature-todo/010-production-ship.md)
(group 5), per [033-production-ship-plan](../.docs/033-production-ship-plan.md), scoped
to the **non-distribution** items (owner owns signing / notarization / Sparkle / Web
Store / extension packaging).

## Summary

- **Extension↔app version handshake.** `GET /health` now returns
  `{ appVersion, minExtensionVersion, maxExtensionVersion }` (added as optionals on
  `CaptureResponse` — nil-unencoded, so the **ingest wire is byte-unchanged**). The
  extension gains pure comparators (`parseVersion` / `compareVersions` /
  `checkExtensionCompatibility`) + a `fetchHealth` wrapper that warns when the extension
  falls outside the app's supported range — instead of drifting silently. Tokens still
  gate `/health`, so the check applies once paired; a missing range (pre-handshake app)
  or a network failure is treated as compatible (no false alarms).
- **Diagnostics export.** Settings ▸ *Export Diagnostics…* writes a plain-text report
  (app/OS versions, supported extension range, endpoint state, library path, DB size,
  snapshot count) to the sandbox temp dir and reveals it in Finder. **No library
  content** — versions, sizes, counts only (local-first: MetricKit + manual export, no
  third-party crash reporter). A shared `AppLog` logging namespace lands alongside.
- **Accessibility (first pass).** Grid cells (`CollectionCell`) are now single VoiceOver
  elements announcing kind + title, selection state, and the tap hint.
- **Scale harness.** A runnable seed-and-time test (`ScaleHarnessTests`) seeds N assets
  and times `collectionItems` + `searchAssets`. Default N=300 (CI-fast); a dev drives a
  real pass with `ATELIER_SCALE_N=20000 swift test --filter ScaleHarness`. Correctness is
  asserted; timings are printed (no latency asserts — those would flake).
- **Localization decision:** **English-only for v1**, explicitly. A String Catalog
  migration stays an additive future step (the door is open, not opened).

## Not in scope (owner owns distribution)

Extension icons / zip packaging, extension-ID pinning (needs the real Web Store ID),
signing, notarization, Sparkle, Web Store listing. The full **10k–50k Instruments /
grid-scroll pass** also remains a manual dev-machine run — the harness seeds + times the
DB layer, but the app UI isn't exercised headlessly.

## Files changed

- `AtelierServer/Sources/AtelierServer/CaptureDTO.swift` — `CaptureResponse` health
  fields + `.health(...)` factory.
- `AtelierServer/Sources/AtelierServer/CaptureServer.swift` — `appVersion` /
  `min`/`maxExtensionVersion` constants; `/health` returns the handshake.
- `AtelierServer/Tests/AtelierServerTests/CaptureServerIntegrationTests.swift` — asserts
  the `/health` version fields.
- `extension/src/endpoint.js` — version comparators + `checkExtensionCompatibility` +
  `fetchHealth`.
- `extension/test/endpoint-health.test.js` — **new**, 9 handshake tests.
- `AtelierRefs/AtelierRefs/Diagnostics.swift` — **new**, `AppLog` + pure
  `DiagnosticsReport.text(from:)`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `diagnosticsFacts()` +
  `exportDiagnostics()`.
- `AtelierRefs/AtelierRefs/SettingsView.swift` — Diagnostics section.
- `AtelierRefs/AtelierRefsTests/DiagnosticsReportTests.swift` — **new**, pure builder +
  no-content assertions.
- `AtelierRefs/AtelierRefs/CollectionCell.swift` — VoiceOver label/traits/hint.
- `AtelierCore/Tests/AtelierCoreTests/ScaleHarnessTests.swift` — **new**, scale harness.

## Verification

- `node --test` (extension) → **379 pass**.
- `swift test` (AtelierCore) → **331 pass** (incl. ScaleHarness); (AtelierServer) →
  **85 pass** (incl. the extended `/health` test).
- `xcodebuild test -only-testing:AtelierRefsTests` → **TEST SUCCEEDED** (incl. the new
  `DiagnosticsReportTests` + `AppUndoTests`).

## Migration notes

None. The health fields are optional (captures unchanged); the extension helpers are
additive; diagnostics/a11y/scale-harness touch no schema, wire contract, or public
service surface.
