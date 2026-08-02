# 317 — The Clipboard Keeps the Asset (019 · C1–C3)

Dragging assets between collections has always kept the asset ROW — its note, its
tags, its `original_url`, its `created_at`. Copy-pasting the same assets quietly
rebuilt them from bytes and lost all of it. This is the 065 §2.4–2.5 dual-write
pattern, which the board already had, applied outside Spaces.

## Summary

- **⌘C writes two representations of one selection.** `copyToPasteboard` still
  writes the byte representation first — blob file URLs, plus an `NSImage` for a
  single item — and now appends an `AssetDragPayload` (`{assetIDs,
  sourceCollectionID}`) after it. Nothing an external app sees changed: Figma,
  Finder and Photoshop keep receiving exactly the file URLs they received before.
- **⌘V in the grid checks ours first.** `CollectionView.paste()` decodes the
  payload and routes to `copyToCollection` — a second *membership* of the same
  asset. Anything else falls through to the unchanged importer.
- **⌘V onto a board places instead of importing.** The same check slots into
  `pasteOntoBoard` between the board's own `SpaceElementPayload` branch and the
  external importer, routing to `SpaceModel.placeDroppedAssets`.

## Why it was broken

Grid ⌘C put only bytes on the pasteboard, so ⌘V had nothing to tell the app's own
clipboard from a file copied in Finder. The paste took the file-URL branch and
re-ingested the blob as a fresh local capture: `platform: .localDrag`,
`originalURL: nil`.

`findDuplicate` matches on blob hash **plus provenance** — same `original_url`
when one is given, else same `platform`. So an asset that arrived as a file
deduped fine and nothing was lost, while a `.web` / `.twitter` / extension-captured
asset **missed**: a new asset row, a new source row, `asset.note` gone, tags gone,
`original_url` / `author` / `title` gone, `created_at` reset to now, and analysis
re-run over byte-identical pixels.

`ServicesClipboardPasteTests.byteReimportForksTheWebAsset` pins that failure
directly, so the reason this branch exists stays legible after the branch itself
looks obvious.

## Order is load-bearing, in both directions

**Writing**: `AssetPasteboardWriter.write` calls `clearContents()`, so the private
payload can only go on *after* it. Written last, it also stays behind the file URL
in the board's type order — `.assetIDs` conforms to `public.data`, so a receiver
that accepts anything could otherwise match it instead of the file. Both halves
are asserted (`orderIsLoadBearing`, `fileURLRemainsPreferred`), the first by
proving the wrong order really does lose the payload.

**Reading**: our representation must be checked *first*. The weaker blob file URL
is still sitting right next to it, and the importer would happily consume it —
which is the original bug, reintroduced one branch lower. `handleDrop` has encoded
this same precedence since 192; paste was the missing half.

## The payload carries the whole selection, the report does not

`AssetExport.exportSelection` splits a selection into `entries` (copyable) and
`skipped`. The private payload is built from the **input** assets, not from
`entries`: pasting by id needs no bytes, so ⌘C→⌘V now works for a media-less
`.unknown` or an image whose blob has gone missing — items that cannot be copied
out of the app at all.

`CopyReport` deliberately keeps counting what the *byte* representation produced.
It is the honest number for other apps, and it is what preserves the "this won't
paste into Figma" warning. The two numbers disagreeing is the point, not a bug.

## Same-collection paste says so

`addAssets` already guarantees one membership, so pasting back where you copied
from changes nothing. Rather than appear to swallow the keystroke, it reports
"Already in this collection." through `reportAlreadyInCollection()` — the same
plain-notice shape `reportUnreadableDrop()` uses for its deliberate no-op.

A copy taken from a membership-less surface (library search, a Space board)
carries `AssetDragPayload.nilSourceID`, the all-zero id `UUID()` never produces,
so it can never masquerade as a same-collection paste.

## Stale ids fail closed

Copy, delete the item, paste. `addAssets` throws `.notFound` inside its
transaction, so nothing is half-added, and `copyToCollection`'s `mutateContents`
surfaces it as an error rather than throwing at the user.

## Files changed

- `AtelierRefs/AtelierRefs/AssetPasteboard.swift` — `AssetPasteboardWriter.appendAssetIDs`,
  the second representation and the "nil, not empty" rule (an empty selection
  writes no payload, so a later ⌘V falls through instead of matching a copy that
  carried nothing).
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `copyToPasteboard` and
  `copySelectedToPasteboard` take a `sourceCollectionID` (required, not defaulted —
  every caller knows its own answer); `reportAlreadyInCollection()`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `PasteRoute` + the pure
  `resolvePaste(payload:target:)`, and `paste()` rebuilt around it. Branch 1 uses
  the SAME `importTargetID` the import branch does, rather than growing a second
  target rule.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — the asset branch in `pasteOntoBoard`
  (its numbered doc comment is now 1–4); board ⌘C passes `nilSourceID`.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — search ⌘C passes `nilSourceID`.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — doc reference to the renamed
  signature.
- Tests (new, 18): `AtelierRefsTests/AssetPasteboardTests.swift` gains
  `AssetPasteboardPayloadTests` (5 — both representations, preference, all-skipped,
  empty, order) and `GridPasteRoutingTests` (6 — pure decode + branch, no DB);
  `AtelierCore/Tests/AtelierCoreTests/ServicesClipboardPasteTests.swift` (7 — the
  membership arithmetic, the stale-id rollback, undo, and the `.web` regression).

## Test results

- `swift test --package-path AtelierCore` — **591 tests in 87 suites passed**.
- `AtelierRefs` scheme (`xcodebuild … test`) — **TEST EXECUTE SUCCEEDED**, 1075
  test cases.

## Migration notes

**None.** Zero schema change, no new pasteboard type (`com.ref-atelier.asset-ids`
has been exported in `Info.plist` since 009 · N3), no service change — branch 1
calls `addAssets`, which the drag path and undo already use.

⌥⌘V ("paste as a genuinely new copy", forcing the old re-import) is deliberately
NOT added: that is what the export/import round-trip is for.
