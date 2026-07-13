# 098 — Item detail: image zoom / pan

Adds pinch-to-zoom and drag-to-pan to the detail page's image
([023-item-detail-plan](../.docs/023-item-detail-plan.md), F4 — previously
parked). Because `ItemDetailView` is presentation-only (`097`), both the
collection grid and the Space board detail pages get it for free.

## Summary

- **`ZoomableImage`** (new subview): a fit-to-view image with
  - `MagnifyGesture` zoom, clamped to `[1, 6]×`;
  - `DragGesture` pan that only engages once zoomed in (a drag at fit is ignored);
  - double-click to snap back to fit + centre.
  Zoom/pan is local `@State`; the media area keys it by `asset.id`, so navigating
  prev/next resets it while the low-res→full-res swap (same id) keeps the current
  zoom. Video is unaffected (AVKit owns its own controls).

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `ZoomableImage`; the image
  branch renders it (keyed by `asset.id`).

## Migration notes

None — additive gesture layer on the image view; the fit-to-view default is the
prior behaviour, so an untouched image looks identical.

## Tests

App builds clean; `AtelierRefsTests` green. Gesture interaction is manual-QA
territory (no unit test); the default (un-zoomed) render is unchanged.
