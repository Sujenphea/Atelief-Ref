# 337 — Eight Things, Written Down

Docs only. No code changed.

Eight reported issues were investigated far enough to name the cause and the file
it lives in, then written up as feature-todo docs. Each carries a verified
"Current state" section with `file:line` references, a design, schema impact,
phasing, tests, risks, and open questions — the [016]/[011] house shape.

## Summary of what the investigation found

- **[072]** — `run-local.command` builds to `build/local-release` and launches
  from there (`:41-42`, `:144`); **no script in the repo ever writes to
  `/Applications`**. The copy at `/Applications/AtelierRefs.app` on this machine
  is from 31 Jul. The reported "carousel detail page ignores arrow keys" is that
  stale bundle — `DetailKeyCatcher` landed 3 Aug. Also: both bundles report
  version `1.0 (1)`, so nothing distinguishes them.
- **[073]** — ⌫ means a *different verb* on each surface: destroy in the grid,
  remove-placement on a board, nothing in item detail. ⌘⌫ is bound nowhere.
  `IngestionModel.removeSelectedFromFolder()` (`:2381`) — the exact verb the
  request wants on ⌫ — exists and has **zero callers**.
- **[023]** — no archive/soft-delete concept exists (schema is at v19; no
  `archived_at`). Note `LibraryArchive*` already means [008]'s backup bundle —
  the word is taken. Second library remains [016] §C's deferred item; two new
  seams recorded.
- **[024]** — ~30 bindings across six independent key-handling sites, documented
  nowhere in the UI. Proposes a pure `KeyMap` table (whose real value is a
  collision test), a Help ▸ Keyboard Shortcuts sheet on ⌘/, and reconciles the
  requested `M`/`A` against [011] C-2's `M`/`⇧M`.
- **[074]** — the sidebar chevron is an `NSImageView` ("indicator only — the row
  handles toggle", `SidebarOutlineKit.swift:144`), so one click both navigates and
  toggles. Rename is context-menu-only; the inline editable cell it needs
  (`SidebarDraftCell`) already exists for the new-item draft.
- **[026]** — item detail's add-to-collection menu is `listCollections()` filtered
  (flat, alphabetical across the whole tree, Unsorted unpinned, uncapped) while the
  correct indented tree sits in `CollectionTargets.moveTargetTree`. No delete
  bindings. Deleting closes the page via the `contentsVersion` auto-dismiss
  (`CollectionView.swift:1040`).
- **[075]** — the grid's right-click Move to ▸ uses `moveTargets` (direct
  subfolders + roots — **one level**), not `moveTargetTree` (the whole hierarchy)
  that the multi-select bar uses. Separately, `keyboardActionTargets`
  (`IngestionModel.swift:2281`) takes the lead's asset id **raw**, skipping the
  post-widening every other action path applies — so ⌫ (and ⌘D) on a collapsed
  ⧉4 tile hits one image, the exact failure `actionTargets` documents itself as
  preventing.
- **[076]** — `CanvasArrange.tidy` has **no width bound**, and `tidyRows` clusters
  by *transitive* overlap (`openBottom` only ever grows), so a dense scatter
  chains into a single row thousands of points wide. `SpaceLayout.flowIn` already
  wraps at `maxRowWidth = 1600`; tidy should not invent a different rule.

## Files changed

- `.docs/072-local-install-lane-plan.md` (new)
- `.docs/073-two-tier-delete-plan.md` (new)
- `.docs/feature-todo/023-archive-and-second-library.md` (new)
- `.docs/feature-todo/024-keyboard-map-and-shortcuts-page.md` (new)
- `.docs/074-sidebar-row-interaction-plan.md` (new)
- `.docs/feature-todo/026-item-detail-gaps.md` (new)
- `.docs/075-grid-destinations-carousel-plan.md` (new)
- `.docs/076-spaces-tidy-wraps-plan.md` (new)

## Migration notes

None — documentation only. The one schema change *proposed* across the eight is
[023]'s `asset.archived_at` (v20, additive, nullable).

## Sequencing worth honouring

Three of these interlock and should not land independently:

1. **[075] G1 before [073] D2.** The lead-widening bug is one line; [073] is about
   to wire a second consumer (`removeSelectedFromFolder`) onto the same broken
   property.
2. **[073] and [075] G1 in one window.** Together they change ⌫ on a carousel tile
   from "destroy one image" to "remove all four from this collection" — two
   surprises unless described as one change.
3. **[026] §A and [075] §G2 share an extraction.** Both need the destination list
   (SwiftUI list / AppKit nested menu) built from `moveTargetTree`. Whichever
   lands first builds the shared piece.
