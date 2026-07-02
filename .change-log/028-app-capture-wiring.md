# 028 — App wiring: entitlement + capture endpoint lifecycle (build-order #6, checkpoint 3)

Wires `AtelierServer` into the app: the sandbox entitlement that lets the listener
bind, the Xcode package dependency, and the endpoint's lifecycle + live-refresh.

## Summary
- **Entitlement (unblocks the listener):** new `AtelierRefs/AtelierRefs.entitlements`
  with `com.apple.security.network.server` (App Sandbox stays ON; keeps the existing
  user-selected read-only file access; no `network.client` — the app never makes
  outbound calls, A3). `CODE_SIGN_ENTITLEMENTS` set on the app's Debug + Release
  configs. Verified: the signed `.app` packages the entitlement.
- **Xcode wiring:** `AtelierServer` added as a local package (`FA…` refs mirroring the
  CanvasRenderer/AtelierCore/AtelierIngestion `CA/DA/EA` pattern) + linked into the app.
- **Lifecycle (CQ1/P4):** `IngestionModel.bootstrap` now starts a `CaptureServer` on
  127.0.0.1:47321 off the launch path after `AppServices` is ready; a bind failure
  (port in use) is surfaced as a status hint, never fatal. Captures route through the
  SAME bounded `IngestCoordinator` as paste/drag, defaulting to Unsorted; the
  `onCapture` callback hops to the main actor to refresh the visible folder + tree.
- **Token:** generated once (`CaptureToken.generate`, 256-bit) and persisted in
  UserDefaults; shown in a new toolbar popover ("Browser Capture") with endpoint
  status, port, and a Copy button to paste into the extension's options.

## Files changed
- Create `AtelierRefs/AtelierRefs/AtelierRefs.entitlements`.
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — entitlements + AtelierServer
  package/product/framework refs.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — capture endpoint start, token
  load/generate/copy, remote-capture refresh hook.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — Browser Capture toolbar popover.

## Migration notes / caveats
- App builds + signs green (`xcodebuild … build` → BUILD SUCCEEDED). Runtime bind
  under the sandbox is now possible but still a MANUAL check (launch the app, confirm
  the endpoint listens) — no automated coverage crosses the sandbox boundary.
- The extension itself lands in checkpoint 4.
