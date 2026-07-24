# 219 — Search results render through the AppKit grid (drag lag fixed)

## Summary

Folded the search results grid into the same AppKit `MasonryGridHost` the
collection grid uses, replacing the bespoke SwiftUI `LazyVGrid` + `.draggable`
implementation. This is work item A of the drag-unification plan
(`.docs/048-drag-unification-plan.md`).

The search drag was laggy because every result cell wrote its frame into a
parent `@State` dictionary (`cardFrames` via `.onGeometryChange`), so a drag —
which reflows/auto-scrolls the grid — continuously invalidated the results
`body` and rebuilt every cell, while `.draggable` also snapshotted the full
384-bucket cell synchronously at drag start. Both causes are now **structurally
gone**: the AppKit host drags through a native `NSDraggingSession` (no SwiftUI
view tree churns during the drag) with a precomputed 84 pt / 192-bucket drag
image.

As a side effect search also gains the full grid reducer behaviour it previously
skipped — marquee band-select and arrow-key cursor — on top of the click / ⌘ /
⇧ / ⌘A / Delete / Esc it already had, all now shared with the collection grid
instead of reimplemented.

## Mechanism

Search hits are `AssetDetail` (membership-less); the host is keyed on membership
`item.id`. The bridge is a synthetic `CollectionItemDetail` per hit with
`item.id == asset.id`, so every host closure keyed on the cell id coincides with
the asset id — no id mapping. A sentinel scope id (`AssetDragPayload.nilSourceID`)
marks every drag-out as a COPY, and a new `.looseAssets` menu style hides the
verbs that need a real membership.

## Files changed

- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `LibrarySearchResults`
  rewritten to host `MasonryGridHost`. Deleted the SwiftUI scaffolding:
  `resultCell`, `.draggable`, `cardFrames`/`.onGeometryChange`, the marquee
  gesture/overlay/`updateMarqueeSelection`, `selectionCircle`, `cellMenu`,
  per-view `GridSelection` `@State` + `apply`, and the `.onKeyPress` handlers
  (the host owns keys now). Added a `GridHostConfiguration` builder, synthetic
  `items`, a `GridSelectionStore`, Finder-scope target helpers, and a small
  precomputed drag preview.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — added a `menuStyle`
  (`GridMenuStyle`: `.collection` / `.looseAssets`) and an `onReveal` closure to
  `GridHostConfiguration`, both defaulted so the collection call site is
  unchanged; `buildContextMenu` switches on the style (loose = Add / Reveal a
  lone byte-backed hit / Delete).

## Migration notes

- No pasteboard/payload format change — `AssetDragPayload` bytes are identical,
  so drops onto sidebar collections/spaces and Finder promise drags are
  unaffected.
- `GridHostConfiguration` gained two defaulted fields; `CollectionView`'s call
  site needs no change.
- Parity gaps (not regressions vs the prior search grid): no Quick Look and no
  ⌘± zoom in search — the host seams are wired to no-ops. Follow-up if wanted.

## Verification

- `xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` — BUILD
  SUCCEEDED. Runtime drag-feel to be confirmed in-app.
