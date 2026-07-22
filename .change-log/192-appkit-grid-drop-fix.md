# 192 — Fix internal drag-drop from the AppKit grid (reorder + move + self-import)

Three symptoms, reported across two rounds:

1. **Reorder within a collection** (drag a cell onto another) did nothing —
   broken since the 036 SwiftUI→AppKit grid migration.
2. **Drag to another collection** (grid → drop rail / Unsorted stack) did
   nothing — same vintage.
3. **Dragging a selection could IMPORT the app's own image again** (a duplicate
   asset) — new since 011 drag-out (191).

Right-click ▸ Move worked throughout because it bypasses drag entirely.

## How it was diagnosed

None of this is drivable headlessly by normal unit tests, so a diagnostic
harness (`DragDropDiagnosticsTests.swift`, temporary) exercised the REAL seams:
a real `NSPasteboard` written by the promise provider, a windowed
`MasonryNSCollectionView` driven by a mock `NSDraggingInfo` (which must shim the
private `_lastDragDestinationOperation` selector AppKit queries), and a windowed
`NSHostingView` replica of the collection pane whose AppKit view tree was dumped.
Findings, each load-bearing for the fix:

- SwiftUI mounts each `.onDrop` as its own `_PlatformDraggingDestinationView`
  registered for `[public.data, public.item]` (catch-alls; the concrete-type
  filter runs inside SwiftUI). The hosting view itself registers nothing.
- The pane-level import `.onDrop([.image, .fileURL, .url])` droppable REFUSES a
  plain `.assetIDs` drag but ACCEPTS a file-promise drag — and since 191 every
  media drag carries file promises, an internal drag matched the import target
  and re-ingested the app's own promised file (symptom 3).
- For a promise-shaped drag, SwiftUI's bridged `NSItemProvider` exposes **zero
  type identifiers** (`registeredTypeIdentifiers == []`), so ANY provider-based
  read of `.assetIDs` finds nothing (why the rail/stack `.onDrop` — and its
  earlier `.dropDestination` incarnation — never fired their accept path:
  symptom 2). The payload bytes ARE on the drag pasteboard the whole time.
- `NSCollectionView`'s `validateDrop`/`acceptDrop` delegate methods never fire
  for a drag started via `beginDraggingSession` (symptom 1); NSView-level
  `NSDraggingDestination` overrides do, and the full chain (registration →
  hit-test → `onCellDrop`) passes against a real windowed collection view.

## Fixes

- **Reorder → NSView-level drop reception.** `MasonryNSCollectionView` overrides
  `draggingEntered` / `draggingUpdated` / `prepareForDragOperation` → `true` /
  `performDragOperation`, forwarding to the coordinator's
  `gridDraggingOperation` / `gridPerformDrop` (analytic-frame hit-test →
  unchanged `onCellDrop` → `routeDrop`/`handleCellDrop`). The dead
  `NSCollectionViewDelegate` drop methods are removed. (Trade: native
  drag-autoscroll-at-edges is not wired — follow-up if wanted.)
- **Cross-collection → read the DRAG PASTEBOARD, not the providers.**
  `AssetDragPayload.fromDragPasteboard()` reads `.assetIDs` straight off
  `NSPasteboard(name: .drag)`; `fromDrop(_:completion:)` tries that first and
  falls back to the provider bridge (`loadFirst`) for SwiftUI-native drags. The
  drop rail rows and stack cards use `fromDrop` inside `.onDrop(of:
  [.assetIDs])` (converted from `.dropDestination`, which never recognised the
  AppKit drag at all).
- **Self-import → the import target refuses internal drags.** The pane-level
  `handleDrop` guards on BOTH channels (drag pasteboard + provider types) before
  ingesting, since a promise drag is invisible on the provider channel.
- **Detail drag-out carries an internal identity too.** The detail view's
  `.onDrag` (a bare file-URL provider — the same self-import class) now builds
  via `AssetExport.dragProvider(item:payload:)`, which also registers
  `.assetIDs`: the collection detail host threads its REAL payload (asset +
  source collection, so routing sees the truth), while the membership-less
  hosts (library search, Space board) pass `AssetDragPayload.internalMarker` —
  an empty-asset payload `routeDrop` rejects at every target, so it marks the
  drag as internal without granting it any drop semantics.

## Files

- `AssetDragPayload.swift` — `fromDragPasteboard()` + `fromDrop(_:completion:)`;
  `loadFirst` demoted to the documented fallback; `internalMarker`.
- `AssetExport.swift` — `dragProvider(item:payload:)` (file + `.assetIDs`).
- `ItemDetailView.swift` — `dragPayload` input (default `.internalMarker`),
  `DetailDragOutModifier` builds via `AssetExport.dragProvider`.
- `CollectionDropRail.swift`, `CollectionStackCard.swift` — `.dropDestination`
  → `.onDrop(of: [.assetIDs])` reading via `fromDrop`.
- `CollectionView.swift` — import `handleDrop` internal-drag guard (both
  channels); `[dragdiag]` logs.
- `MasonryGridHost.swift` — NSView-level drop overrides + coordinator
  `gridDraggingOperation`/`gridPerformDrop`; removed the delegate drop methods;
  `MasonryGridViewEvents` gains the two drop hooks; `[dragdiag]` logs.
- Tests: `AssetDragPayloadDragPasteboardTests` (drag-pasteboard read incl. the
  exact promise-provider shape, `fromDrop` preference/fallback/absence),
  `AssetDragPayloadBridgeTests` (provider fallback). The diagnostic harness
  (`DragDropDiagnosticsTests.swift`) was deleted once its findings were pinned
  here and by the permanent tests — it destabilised unrelated suites (main-run-
  loop spins + windowed hosts perturbed the thumbnail pipeline's timing tests).

## Verification

- `xcodebuild test -only-testing:AtelierRefsTests` → TEST SUCCEEDED (incl. the
  diagnostics suite that pins the droppable behaviour + drop chain).
- **Manual: VERIFIED live** (temporary `[dragdiag]` seam logs, since stripped):
  reorder routes and applies (`route=reorder … accepted=1`), stack-card move
  decodes via the pasteboard read and lands (`fromDrop found=1` →
  `handleCollectionDrop`), and the import guard blocks the self-import
  (`pane import REFUSED internal drag`). External imports and drag-out
  unaffected. The detail-drag identity (below) is covered by unit tests; its
  in-app drop is the same guard path.

## Migration notes

None. No schema / wire / service change. Pure view-layer drop wiring.
