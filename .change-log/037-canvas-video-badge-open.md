# 037 — Canvas: ▶ badge + double-click open-to-play (video capture, checkpoint D)

Makes captured videos legible and playable on the canvas. A video already
rendered as its poster tile (checkpoint C); this adds the affordance + playback.

## Renderer (CanvasRenderer) — a small, generic seam
- `TileProvider` gains `badge(for:) -> TileBadge?` (defaulted to `nil`, so existing
  providers/tests are unchanged). `TileBadge` is a minimal enum (`.play`) — the
  renderer stays asset-agnostic; the app maps `kind == .video → .play`.
- `CanvasEngine` overlays a ▶ badge layer (a translucent disc + white triangle,
  rendered once, shared via `contents`) centred on each badged tile, sized to the
  tile's on-screen size and hidden when too small. Badge layers are siblings of
  tile layers tracked in their own dict — they never touch the recycling
  `LayerPool`, and are dropped when a tile leaves the viewport.
- `CanvasEngine.tile(atScreenPoint:)` — topmost visible tile under a point.
- `CanvasHostView` handles a double-click → hit-test → `onActivateTile(id)`
  callback (single-click / scroll / pinch unchanged); `CanvasView` threads the
  closure.

## App (AtelierRefs)
- `CanvasContent.badge(for:)` returns `.play` for `.video` tiles;
  `videoURL(forTileID:)` resolves the tile's on-disk blob URL (mirrors
  `IngestionModel.blobURL`).
- `QuickLookPresenter` (new) opens the video in an inline `QLPreviewView` window
  (imported from `Quartz`/QuickLookUI — `QuickLook` alone lacks the view). It
  plays AV itself, so no responder-chain wiring.
- `CanvasScreen` wires double-click → `quickLook.present(url:)`.

## Verification
- `swift test` (CanvasRenderer) → **72/72** (+6: badge only on video tiles, none
  otherwise, badges dropped off-screen, hit-test resolution incl. gaps + topmost).
- App builds + signs (macOS, Debug).

## Files changed
- `CanvasRenderer/.../TileProvider.swift` (+TileBadge/badge),
  `Host/{CanvasEngine,CanvasHostView,CanvasView}.swift`,
  `Tests/.../VideoTileTests.swift` (new).
- `AtelierRefs/.../{CanvasContent,CanvasScreen}.swift`,
  `AtelierRefs/.../QuickLookPresenter.swift` (new).
