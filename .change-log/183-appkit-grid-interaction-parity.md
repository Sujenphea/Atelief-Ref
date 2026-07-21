# 183 — AppKit grid: interaction parity (036 §4 A3)

Completes interaction parity on the AppKit grid path (`AtelierUseAppKitGrid`,
still **default OFF**): drag out, drop onto a cell, a native context menu, the
marquee (+ edge auto-scroll + the A2-deferred empty-background click-to-clear),
and GIF hover. Every piece funnels through the SAME proven components the SwiftUI
path used — `AssetDragPayload`, `routeDrop`/`handleCellDrop`, `MoveTargetsCache`,
the `.marquee(hits:base:)` reducer + `masonryMarqueeIndices`, `DisplayLinkPump`,
`GifAnimationCoordinator` + the pure GIF policy fns — so this is a new AppKit
*delivery* front-end, not a reimplementation. Flag OFF stays byte-for-byte
today's behaviour; the SwiftUI grid / drop rail / stack row / Spaces / pane-level
`.onDrop` are untouched.

## Context-menu decision: native `NSMenu` (not C4's SwiftUI menu)

§4 A3 offered either. **Chosen: native `menu(for:)`** on the collection view.
Justification: C4 already removed the per-cell menu cost, so the deciding factor
was right-click *reliability*, not perf. Keeping C4's SwiftUI `.contextMenu` over
the `NSCollectionView` host would have to re-plumb hover + the AppKit scroll
offset back into SwiftUI and fight the collection view's own first-responder /
event handling — fragile and prone to silently not firing. The native path is
self-contained in the coordinator, deterministic, and **reuses every pure piece**:
`actionTargets`' Finder-scope rule (right-click inside the selection acts on the
whole selection, outside on the one cell), the memoized `MoveTargets`, and the
same action closures. Menu contents / submenu order / counts / scope are
byte-identical to the SwiftUI `cellMenu`. It does NOT draw a system targeted-cell
highlight (C4's `GridContextHighlightLayer` is SwiftUI-only) — a cosmetic gap.

## What's wired (flag on)

- **Drag out.** The A2 threshold loop's `beginDragHandoffStub` is now a real
  `NSDraggingSource` session. Pasteboard = `JSONEncoder().encode(AssetDragPayload)`
  under `com.ref-atelier.asset-ids`, byte-compatible with SwiftUI's
  `CodableRepresentation`. Drag image = `ImageRenderer` over the existing
  `dragPreview`; a selected cell drags the whole selection (via
  `IngestionModel.dragPayload`).
- **Drop onto cell.** The collection view registers ONLY `.assetIDs`; an external
  file/image/URL drag is not a registered type and falls through to the pane-level
  SwiftUI `.onDrop`. `validateDrop` hit-tests the analytic frame and forces `.on`
  (a drop on a gap is rejected → no-op, as in SwiftUI); `acceptDrop` decodes and
  routes through the unchanged `handleCellDrop`/`routeDrop`.
- **Context menu.** Native `NSMenu` (above).
- **Marquee.** New `GridMarqueeController`: `mouseDown` on empty space begins the
  box, `mouseDragged` recomputes hits + redraws per tick, the rectangle is ONE
  flipped hit-transparent overlay view (single layer, content-space top-left frame
  matching the item views — no reliance on layer `isGeometryFlipped`, the coordinate
  trap the brief warns about; `CATransaction` with actions disabled, no view
  rebuilds), and edge auto-scroll reuses `DisplayLinkPump`'s pt/sec × frame-dt
  velocity ramp intact.
  A bare (un-⇧) background click clears the selection (the A2-deferred
  click-to-clear); a ⇧-click no-ops — exact SwiftUI semantics.
- **GIF hover.** Dwell task + `GifAnimationCoordinator.claim/release` ported into
  `MasonryGridItem`, reduce-motion via `NSWorkspace.accessibilityDisplayShouldReduceMotion`,
  the pure policy fns reused as-is; the proven `AnimatedGifView` plays through a
  hit-transparent host. `prepareForReuse` cancels the dwell AND releases the slot.

## Coordinate handling

One helper `contentPoint(for: NSEvent)` on the coordinator
(`collectionView.convert(event.locationInWindow, from: nil)`) is the single event
→ content-space conversion for click / marquee / menu / drag; hover already used
the identical conversion. Clicks inside the `topInset` or past the content bottom
convert fine and hit-test to no cell → treated as empty space (marquee / clear),
never a mis-hit. All hit-testing rides the ANALYTIC frames
(`layout.solvedFrames` / `hitTestIndex`), never the pixel-snapped live cell frames
(038 §3.4).

## Files changed

- `AtelierRefs/AtelierRefs/GridMarqueeController.swift` — **new.** AppKit marquee:
  background rubber-band, single-`CALayer` rectangle, click-to-clear, and
  `DisplayLinkPump` edge auto-scroll. Hits map via the new pure `marqueeHitIDs`.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — config gains the A3 seams
  (`dragPayload`/`dragImage`/`onCellDrop`/`actionTargets`/`moveTargets` + the five
  menu action closures); coordinator conforms to `NSDraggingSource` +
  `NSCollectionViewDelegate`, adds `contentPoint`, `beginDragHandoff`, background
  mouse handlers, `gridMenu(for:)` + `buildContextMenu`/`targetSubmenu`, the
  drop validate/accept, and the marquee wiring; `MasonryNSCollectionView` forwards
  background mouse + `menu(for:)`. `BlockMenuItem` helper.
- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — GIF hover: `configure` takes
  `gifURL`, `setHovered` drives the dwell/claim/release, hit-transparent gif host,
  `prepareForReuse` releases the slot.
- `AtelierRefs/AtelierRefs/MasonryCollectionLayout.swift` — `solvedFrames` accessor
  (full analytic frame array for the marquee).
- `AtelierRefs/AtelierRefs/MarqueeMath.swift` — new pure `marqueeHitIDs`.
- `AtelierRefs/AtelierRefs/AssetDragPayload.swift` — `pasteboardType` /
  `pasteboardData()` / `makePasteboardItem()` / `decode(from:)` (the byte bridge).
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `appKitGrid` populates the new
  config closures (all forward to existing model/view seams). Flag-off untouched.
- `AtelierRefs/AtelierRefsTests/AssetDragPayloadTests.swift` — pasteboard byte
  round-trip vs the SwiftUI `CodableRepresentation` wire form + UTI match.
- `AtelierRefs/AtelierRefsTests/GridMarqueeControllerTests.swift` — **new.** The
  flipped-space rect→ids mapping over real masonry frames, incl. the `topInset`
  and past-content-bottom cases and the frames/ids length-skew guard.

## How byte-compat is proven

SwiftUI's `CodableRepresentation(contentType:)` serializes with a plain
`JSONEncoder` under the content type's identifier. `AssetDragPayloadTests` pins
all three: `payload.pasteboardData() == JSONEncoder().encode(payload)`, it decodes
back through the same `Codable` form a drop uses, and `pasteboardType.rawValue ==
UTType.assetIDs.identifier == "com.ref-atelier.asset-ids"`. A drift in any breaks
drag-to-rail and a test fails. (The live `NSDraggingSession` → SwiftUI
`.dropDestination` bridge itself is owed to the A4 soak.)

## Parity notes per feature

- **Drag out.** Multi-select carries the whole selection; single-cell carries
  itself. Flipped drag-image origin is centred on the pointer (cosmetic; a small
  offset can't change the drop payload).
- **Drop.** Reorder only for a same-collection manual-sort drop (via `routeDrop`);
  a drop on a gap no-ops; external drops fall through — **the clean register-only
  path, NOT register+forward.**
- **Context menu.** Native `NSMenu`; contents/scope identical to `cellMenu`. No
  system targeted-cell highlight (cosmetic).
- **Marquee.** Full parity EXCEPT one gap: a click in the dead area BELOW a SHORT
  collection's content (content shorter than the viewport) does not clear — the
  AppKit document view stops at content height, unlike the SwiftUI capture layer
  that fills the viewport. Any real gap between/around cells clears; target-scale
  collections never reach this region.
- **GIF hover.** Dwell + single-slot + budget + reduce-motion identical; released
  on reuse.

## Verified vs owed to the A4 soak

**Verified (unit + build):**
- Release build `xcodebuild build … -configuration Release` exit **0**; no new
  warnings from the changed files (the lone `CollectionView.swift` `.dropDestination`
  "result unused" warning is pre-existing — it was `:806` in A2, renumbered to
  `:825` by this step's additions — in an untouched SwiftUI line).
- `-only-testing:AtelierRefsTests -parallel-testing-enabled NO`: **428 tests / 70
  suites passed**, incl. the new marquee-hit and pasteboard-byte tests; every
  pre-existing (flag-off) suite green.

**Owed to the A4 soak (cannot run headlessly — named, not verified):** the
`NSDraggingSession` round-trip to the still-SwiftUI drop targets; external-drop
fall-through (if it turns out AppKit eats it, the register+forward fallback
applies); `menu(for:)` delivery; `NSTrackingArea` / live cell recycling; the
marquee `CALayer` z-order + flipped rendering; first-responder fights; and the
NSHostingView leak-after-2k check.

## Migration notes

None. Flag defaults OFF; no data or schema change. Rollback = flip the flag or
revert this commit. A4 flips the default after the soak and deletes the old
SwiftUI path (keeping `DisplayLinkPump`, which this step reuses).

## Amends to `.docs/036`

An "As built in A3" block is appended to §4 A3 recording the native-menu decision,
the register-only (not register+forward) drop, the marquee dead-zone parity gap,
and the soak-owed items.
