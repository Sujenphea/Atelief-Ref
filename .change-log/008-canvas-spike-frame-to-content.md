# 008 — Canvas spike: fix blank canvas (frame to content)

**Fix** for the Phase 1 canvas harness.

## Problem

The app opened to a **blank page**. The dummy tiles are scattered across ±20,000
world units, but `CanvasHostView` started at the default transform (scale 1,
translation 0) — the world origin, which sits on empty space. (The benchmark and
invariant tests didn't catch it because they set an explicit framing transform;
the app harness never did.)

## Fix

Added `CanvasEngine.frameToContent(padding:)` — computes the union of all tile
world-frames and sets a centred fit-to-viewport transform (clamped, so it stays
centred even at a zoom limit). `CanvasHostView` calls it once on first layout
(guarded by `hasFramedContent`); later resizes just re-sync so they don't stomp
the user's pan/zoom.

## Files changed

- `Sources/CanvasRenderer/Host/CanvasEngine.swift` *(modified)* —
  `frameToContent(padding:)`.
- `Sources/CanvasRenderer/Host/CanvasHostView.swift` *(modified)* — frame on
  first layout only.
- `Tests/CanvasRendererTests/HostTests.swift` *(modified)* — regression test:
  with the app's exact config, `frameToContent` makes >1,000 tiles visible and
  centres content at the viewport centre.

## Verification

- `swift test` — **67 tests in 14 suites passed** (incl. the new regression).
- `xcodebuild build -scheme AtelierRefs` — **BUILD SUCCEEDED**.
- Note: headless pixel capture isn't available in this environment, so the final
  visual confirmation (run AtelierRefs → board fills the window, pan/zoom smooth)
  is a manual check.

## Migration notes

None — additive. `frameToContent` is also useful at step 5 as a "zoom to fit"
action.
