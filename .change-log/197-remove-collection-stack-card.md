# 197 — Remove the collection stack card

## Summary

Follow-up to 196. Removed the `CollectionStackCard` — the Procreate-style fanned
"stack" drop target (`009 · N4`) that once lived on the Unsorted screen. It was
already orphaned after the earlier Unsorted stack-row removal (only its own
preview referenced it), and 196 left it in place. This deletes the dead view plus
the app-side model plumbing that fed it.

## Files changed

- **Deleted** `AtelierRefs/AtelierRefs/CollectionStackCard.swift` — the
  `CollectionStackCard` + `StackDropTarget` views and the `fanRotations` helper.
- **Deleted** `AtelierRefs/AtelierRefsTests/FanRotationsTests.swift` — only
  exercised `fanRotations`, which is gone.
- `IngestionModel.swift` — dropped the now-dead `stackPreviews` published state,
  the `loadsStacks` gate, and the `collectionStackPreviews()` read + republish
  block in `loadContents`. That funnel now runs two concurrent reads (items,
  subfolders) instead of three.
- `CollectionView.swift`, `AssetDragPayload.swift`, `MasonryGridHost.swift`,
  `DropRouter.swift`, `AssetDragPayloadTests.swift` — updated doc comments that
  named the removed "rail / stack row" as the cross-collection drop path; they
  now point at the sidebar rows / "Move to" menus.

## Migration notes

- The Core `AppServices.collectionStackPreviews(...)` service and the
  `CollectionStackPreview` type are LEFT in place — they are lower-level, still
  independently covered by `ServicesMoveTests`, and removing them is a separate,
  larger change. They are simply no longer called from the app.
- No behavior change to drop routing: cross-collection moves already flowed
  through the sidebar rows and "Add to" / "Move to" context menus.

## Verification

- `xcodebuild -scheme AtelierRefs -destination 'platform=macOS' build` →
  **BUILD SUCCEEDED**.
