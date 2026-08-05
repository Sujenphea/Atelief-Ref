# 023 — An Archive Shelf, and the Second Library Behind It

> "A feature to have another library / archived section." Two requests that look
> alike and are not: **archive** is a place inside this library for things you
> don't want to see; **another library** is a second container entirely.
> Archive is small and should be built; the second library is [016] §C, still
> deferred, and this doc says what archive must not do to it.

## Current state (verified)

- **No archive concept anywhere.** `AtelierCore/Persistence/` has no `archived`,
  `is_archived`, `deleted_at` or any soft-delete column; the schema is at **v19**
  (`Migrator.swift`), so an additive column would be `v20`.
- The only "out of sight" states that exist are:
  - deletion — `deleteAssetsRecoverable` (`AppServices.swift:1371`) captures a
    `DeletedAssetsBackup` for ⌘Z, but it is a *transaction-scoped* undo, not a
    browsable shelf. Blobs are reaped at the next launch.
  - Unsorted — the opposite of an archive (a to-do pile).
- "Archive" is already a **taken word** in this codebase and means something else:
  `LibraryArchive` / `LibraryArchiveWriter` / `ArchiveExportController` are
  [008]'s portable `.atelier` backup bundle. **Do not overload it.** Use *Shelf*,
  *Archived*, or *Vault* in code; user-facing copy can still say "Archived" if the
  export surface is renamed to "Backup" consistently.
- **Second library**: [016] §C already records the seams (`LibraryLayout` root is
  injected; the capture server + token are per-app not per-library; UserDefaults
  keys are un-namespaced). Nothing has regressed those.

## A — the archive shelf (build this)

### What it is

A per-asset flag that removes an asset from **every browsing surface** without
touching its memberships, its blob, or its history. Unarchiving restores it
exactly where it was — that is the whole point, and it is what a delete cannot
offer.

### The shape

**`asset.archived_at TIMESTAMP NULL`** — a nullable timestamp, not a boolean.
Same cost, and it buys the sort order ("recently archived" first), the "archived
3 months ago" copy, and any future auto-purge policy, for free.

Reads: one predicate, added at **the funnels, not the call sites** —

- `collectionItems(...)`, the [P14] joined read behind every grid;
- the space content read;
- [003]'s `asset_fts` search query;
- the Collections gallery / space fan previews and their counts.

The rule is `archived_at IS NULL` **unless the caller is the Archived surface**,
so it rides one `includeArchived: Bool = false` parameter through the read layer.
Getting this wrong in one place is how an archived item resurfaces in a count but
not a grid, so the parameter must be on the funnel signature, not defaulted per
query.

### The surface

A sidebar destination beside Home / Spaces — **not** a collection. It is a view
over `archived_at IS NOT NULL` ordered newest-first, reusing the existing grid
host wholesale. Actions on it: **Unarchive** (clears the timestamp; the item
returns to its collections), **Delete** ([073]'s ⌘⌫, unchanged), and open detail.
Nothing else — no move, no add-to, no reorder: an archive you can reorganise is
just another collection.

Reachable from everywhere an item is: context menu "Archive", and a binding
worth having ([024] owns the map — `E` for a bare-key triage verb is the natural
slot next to `X`).

### Why a flag rather than a system collection

A reserved collection (the Unsorted pattern) was considered and rejected:
archiving would then *change memberships*, so unarchiving could not restore them,
and every "is this item in collection X" query would need to special-case the
reserved id anyway. The flag leaves memberships untouched, which is what makes
the round-trip lossless.

### Interactions

- **[073] delete**: ⌫ (remove) and archive are different verbs — remove drops one
  membership, archive hides the asset from all of them. Both stay.
- **[008] backup**: `archived_at` ships in the manifest and round-trips, or a
  restore silently un-archives the user's whole shelf.
- **[016] stats**: the Library pane should report archived count + bytes — that
  is precisely the "what can I reclaim" question archive creates.
- **Blobs are NOT reaped for archived assets.** Archive is not a delete; the
  orphan sweep must skip them explicitly, or the shelf becomes a shelf of
  missing files.

## B — another library (still deferred — [016] §C)

Nothing here changes that verdict. Two additions to the seam list, both created
by work landed since [016] was written:

6. `Collection.unsortedID` is referenced as a **constant** in UI code
   (`ItemDetailView.swift:1110`, and the `unsortedID` parameter threaded through
   `CollectionTargets`). If Unsorted becomes per-library, every one of those is a
   lookup, not a constant. Keep threading the id as a parameter — the existing
   `CollectionTargets` signatures already do this correctly; don't let new code
   reach for the static.
7. `archived_at` (A, above) is per-asset and therefore per-library by
   construction — no new coupling, provided the Archived sidebar destination
   scopes to the active library like every other destination.

If the second library is ever wanted sooner, the cheapest honest version is
**"open a different library root"** (relaunch-scoped, one window, one server) —
the `-library-root` launch argument already exercised by the grid bake-off
already proves the injection works. Simultaneous libraries in two windows is the
expensive version and is what [016] §C actually deferred.

## Schema / migration impact

- **v20**: `ALTER TABLE asset ADD COLUMN archived_at`. Additive, nullable, no
  backfill. A partial index `WHERE archived_at IS NOT NULL` only if the Archived
  view proves slow — the un-archived predicate is the hot one, and it is a null
  check on a column that is null for ~everything.
- [008]'s manifest gains one optional field.

## Phased implementation

1. **A1 (S)** — v20 migration + `archive` / `unarchive` in `AppServices` + the
   `includeArchived` parameter on the read funnels.
2. **A2 (M)** — the Archived sidebar destination (grid host reuse) + Unarchive.
3. **A3 (S)** — archive verbs on grid / detail / space context menus + the key
   binding ([024]).
4. **A4 (S)** — [008] manifest field + orphan-sweep exclusion + [016] stats row.
5. **B (0)** — discipline only; no code.

## Test strategy

- Round-trip: archive → absent from collection read, space read, search, counts,
  gallery previews → unarchive → **byte-identical memberships and order**.
- The funnel predicate: a test that enumerates every read entry point and asserts
  each honours `includeArchived` (the leak this design is most exposed to).
- Orphan sweep over a library whose only reference to a blob is an archived asset
  → blob survives.
- Backup round-trip with archived items ([008]'s existing suite, extended).
- Delete an archived item → normal recoverable delete; ⌘Z restores it *archived*.

## Effort: **A: M total (A1 S · A2 M · A3 S · A4 S) · B: 0**

## Risks & edge cases

- **The word collision with `LibraryArchive`** is the single likeliest source of
  confusion in this doc's implementation. Pick the code name before writing a line.
- An archived item that is a **collection cover** — the cover query must fall
  back rather than render a hole (same class of bug as a deleted cover).
- An archived item **placed on a Space board**: does the tile vanish? Recommended
  **yes** (archive means "not in my working set"), and unarchive restores the
  placement — which only works because the placement row is untouched.
- Counts are the sneaky surface: a collection reading "12 items" while showing 9
  is worse than either number being wrong.

## Open questions

1. Code name — `Shelf`, `Archived`, or rename the backup writer instead?
2. Does archiving a **collection** (not just an asset) make sense, and does it
   archive its contents? (Recommended: v1 is assets only.)
3. Auto-purge after N months — offer it, or never? (Recommended: never
   automatically; surface age in [016]'s stats and let the user act.)
4. Second library: is the relaunch-scoped "open another root" version wanted
   sooner than the full multi-library work?
