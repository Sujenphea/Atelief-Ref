# 194 — Space refresh fixes (sidebar + navigation)

## Summary

Root-caused and fixed the two space-refresh bugs in the 006 shell:

1. **Space→space navigation showed the previous space.** `.space(A)` → `.space(B)`
   only mutates `nav.sidebarSelection`, so both render through the same
   `case let .space(id)` ViewBuilder branch and SwiftUI kept the old `SpaceView`
   identity — its `@StateObject SpaceModel` (immutable `spaceID`, loads once in
   its own init) was never rebuilt. Fixed by keying identity with `.id(id)` in
   `AppShellView.spaceDestination`, which re-runs the `@StateObject` autoclosure
   per space. Covers the legacy pushed route too.
2. **Deleting the selected space left a dangling selection.** Nothing reset a
   `.space` `sidebarSelection` after delete (`pruneRestoredPathIfMissing` guards
   `.collection` only), so the sidebar lost its highlight while the panel kept a
   zombie board. Fixed with an `.onChange(of: model.spaces)` in `AppShellView`
   that falls back to Home when the selected space vanishes — guarded so the
   pre-first-load empty list can't kick a live selection.
3. **Spaces section had no loading/empty state.** `spacesSection` rendered a bare
   header whenever `model.spaces == []`, so "not loaded yet", "load failed", and
   "no spaces" were indistinguishable — a regression of the 034 P2 loading-flash
   fix that lived in the now-retired `SpacesListView`. Ported the contract:
   `spacesLoaded` flag set after the sidebar's `.task` refresh, redacted skeleton
   rows before it, a "No spaces yet" row after.
4. **Space rows used 12pt gaps vs the Collections rows' 4pt.** `spacesSection`'s
   `ForEach` sat directly in the section-level `md` VStack; wrapped it in the
   same inner `VStack(spacing: Theme.Spacing.xs)` `collectionsSection` has.

5. **Launch race: sidebar `.task` vs `bootstrap()` — real, despite analysis to
   the contrary.** Static reasoning said bootstrap's main-actor task (enqueued in
   `IngestionModel.init`) always sets `services` before the sidebar's `.task`
   runs; in practice the `.task` can run first, so its `refreshSpaces()` hit the
   `guard let services` and no-oped — with fix 3 that surfaced as a permanent
   "No spaces yet" at launch. Fixed by making `bootstrap()` own the load
   (`await refreshSpaces()` beside `refreshFolders()`), so the list never
   depends on task-scheduling order; the loaded flag moved into the model
   (`spacesLoaded`, set only after a refresh against an open library) so a
   no-oped pre-bootstrap call can't flip the sidebar to the empty state. The
   sidebar `.task` is kept as a redundant refresh for re-mounts.

The rest of the spaces mutation pipeline was verified clean: every live mutation
path awaits `refreshSpaces()`, and no external writer (capture server /
extension) touches the space table.

## Files changed

- `AtelierRefs/AtelierRefs/AppShellView.swift` — `.id(id)` on `SpaceView` in
  `spaceDestination`; dangling-space-selection prune via
  `.onChange(of: model.spaces)`.
- `AtelierRefs/AtelierRefs/SidebarView.swift` — skeleton / "No spaces yet" rows
  in `spacesSection` (driven by `model.spacesLoaded`); inner `xs` VStack for row
  rhythm.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `bootstrap()` calls
  `refreshSpaces()`; new `@Published private(set) var spacesLoaded`.

## Migration notes

None — UI-only. Known residual (deliberately not fixed here):
`newSpaceFromCollection` commits the space row before seeding items in separate
transactions; a mid-seed failure skips `refreshSpaces()` and leaves a real space
invisible until the next refresh (it does raise the error alert). Proper fix is a
single transactional `createSpace(seedingWith:)` in AtelierCore.
