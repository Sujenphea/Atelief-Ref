# 331 — A Star You Can Take With You (011 · U5 · favorites)

Favourites: `asset.is_favorite`, ⌘D over a selection, a star in the grid and on
the detail page, a filter token in search — and, because the portability archive
now exists, **the manifest carries it**.

That last part is the reason this landed on the backup line rather than on its
own. `LibraryArchive` was written when favourites did not exist (068 says so, in
two places, and both are now amended). Shipping the flag without extending the
manifest, the reader and the replay layer would mean the **first archive written
after this change silently drops every star** — and favourites are user intent,
not derived data, so nothing could recompute them.

**This has a migration: v19.** See the migration notes at the bottom.

## Summary

**Schema + Core (`AtelierCore`)**

- **`Migrator` v19** — `ALTER TABLE asset ADD COLUMN is_favorite INTEGER NOT NULL
  DEFAULT 0`. Additive, constant-defaulted, no rebuild, no back-fill (there is no
  prior signal to recover). `"v19"` appended to `registeredIdentifiers` **and** to
  the pinned list in `MigrationAppendOnlyTests` in the same commit.
- **No index, deliberately.** P13 is "index the paths that scale". The favourites
  conjunct rides `searchAssets`, which is already clamped to ≤500 rows and is
  normally narrowed further by FTS, a tag set or a collection scope — so the
  planner reaches `is_favorite` with a small row set in hand. A partial
  `WHERE is_favorite = 1` index is the right answer *if* a favourites-only sweep
  of a large library ever measures hot; it can be added by a later migration
  without touching v19, which is exactly why it was not added speculatively. A
  test pins the absence, so adding one later is a deliberate act.
- **`Asset.isFavorite`** — a property of the **asset**, never of a membership: an
  asset in three collections is favourited in all three. A test asserts the column
  did not appear on `collection_item`, where a second per-folder "favourite" could
  diverge from it.
- **`AppServices.setFavorite(_:for:)`** (batch + single) — one transaction, and
  **idempotent by construction**: the `UPDATE` is filtered to rows not already at
  the target value, so favouriting a favourite writes nothing and the returned
  count is the number of rows that actually *changed*. That count is what the
  shell builds undo on. A missing id is ignored rather than thrown (a multi-select
  can name a tile deleted a moment ago); `setName` / `setNote` still throw, and the
  difference is documented at both.
- **`AppServices.favoritedAssetIDs(among:)`** — the read half of the ⌘D rule.
- **`searchAssets(favoritesOnly:)`** and **`semanticSearchAssets(favoritesOnly:)`**
  — a plain AND conjunct (`asset.is_favorite = 1`), composing with text, tags,
  platform and collection scope. Both modes, so flipping keyword → meaning does
  not silently drop a filter the user can still see selected.

**Archive (`AtelierRefs`)**

- **`ArchiveManifest.AssetEntry.isFavorite`** → wire key `is_favorite`, written
  unconditionally. `AssetEntry` gains a hand-written `init(from:)` whose only job
  is `decodeIfPresent` on that one key — see the versioning note below.
- **`LibraryArchiveReader`** → `ImportItem.isFavorite`; **`ImportReplay`** applies
  it through `setFavorite`.
- **`.docs/068-backup-portability-plan.md`** — the two sentences claiming
  favourites do not exist are marked superseded, and an amendment records the
  manifest change and the versioning decision.

**App**

- **⌘D** (Edit ▸ Favorite / Remove from Favorites) over the grid selection, via the
  focused model. Undoable, like Remove and Move.
- **Grid star** — `FavoriteBadge`, one cached `NSImage` in a `CALayer` at the
  cell's **bottom-leading** corner (top-leading is the carousel chip, top-trailing
  is the selection circle; bottom-leading is the only corner nothing else claims).
  Hit-transparent, and announced by VoiceOver, since a pixmap is otherwise
  sighted-only.
- **Detail-page star** — a top-bar pill beside the overflow menu, wired on all
  three hosts (collection, search, Space). Keeps a local optimistic state re-seeded
  on every prev/next step, the same shape the Name / Note fields use.
- **`SearchToken.favorites`** + a **star chip in the collection screen's toolbar**.
  The chip and the token are one piece of state with two views of it: clicking the
  chip adds the token (which renders in the field), and the field's `×` clears it.

## The ⌘D multi-select rule

> **⌘D favourites the selection unless every target is already a favourite, in
> which case it unfavourites all of them.**

A mixed selection therefore **converges to "all starred"** rather than flipping
each item. Two reasons, both load-bearing:

- A per-item flip leaves a mixed selection just as mixed as before — the user
  would have to inspect every tile to know what happened. "Star them all" is the
  only outcome that is predictable without looking.
- One more press is still the inverse: after ⌘D the set is uniform, so a second
  ⌘D unstars it. The shortcut reads as a toggle even though it is not a per-item
  one.

The menu item's title states the rule out loud — "Favorite" whenever the press
would star something (including over a mixed selection), "Remove from Favorites"
only when every target is already starred.

Only the ids the press actually **changes** are handed to the writer, so the toast
says "Favorited 1 item" rather than claiming three writes, and **undo restores the
mixture** rather than clearing the lot.

## `manifest_version` stays 1 — and why that is the safe answer

The archive's rule is "a reader that does not recognise the number must refuse
rather than guess". The question that actually implies is: *would a reader that
ignores unknown keys **misread** this file?*

For `is_favorite` the answer is no. It is a new optional key; `JSONDecoder` skips
keys it has no property for, and every field a v1 reader does read still means
exactly what it meant. Bumping would spend the one signal reserved for a genuinely
incompatible change — a field removed, renamed, or given a new meaning — on a
change that is not one, and would make every future additive field look like a
break.

**The "an older build must not mis-read a newer archive" guarantee is carried by
the other version axis, and carried more precisely.** Favourites is a schema
change, so an export records `schema_version = "v19"`, and
`ArchiveManifest.refusal` returns `.schemaTooNew("v19")` for any build that only
migrates to v18. That build refuses the archive **whole** — it never reaches the
point of dropping a star it does not understand. A test pins both halves.

In the other direction, a pre-v19 archive decodes with `is_favorite` absent, read
as `false` — the truth for a file written before the flag existed. That is what
the hand-written `AssetEntry.init(from:)` is for: Swift's synthesized `Decodable`
calls `decode`, not `decodeIfPresent`, for a non-optional property, and a default
value on the declaration does nothing for it. Without that initializer, **every
archive written before v19 would fail to decode entirely** — the whole
compatibility argument rests on one line, and a test fails loudly if it is
deleted.

## Replay applies the star like a tag, not like a name

`ImportReplay`'s rule 3 splits on whether a write can destroy something. Tags are
applied whichever way an asset resolved, because applying one only ever *adds*
information; `name` and `note` are applied only to a newly created asset, because
overwriting them on a dedup hit would discard an edit made in *this* library.

The star sits with the tags. And an archive's `is_favorite: false` is **never
replayed at all** — "not a favourite" is the absence of a claim, not an
instruction to unstar something. So re-importing an old archive can never clear a
star the user set here, which is its own regression test.

## Files changed

**AtelierCore**
- `Sources/AtelierCore/Persistence/Migrator.swift` — v19 registered + `createV19Schema`.
- `Sources/AtelierCore/Domain/Asset.swift` — `isFavorite` + `is_favorite` coding key.
- `Sources/AtelierCore/Services/AppServices.swift` — `setFavorite` ×2,
  `favoritedAssetIDs(among:)`, the `favoritesOnly` conjunct in `searchAssets` and
  `semanticSearchAssets`.
- `Tests/AtelierCoreTests/MigrationTests.swift` — pinned list + `MigrationV19Tests`.
- `Tests/AtelierCoreTests/ServicesFavoritesTests.swift` (new).

**AtelierRefs**
- `LibraryArchive.swift` — `AssetEntry.isFavorite`, its coding key, the
  hand-written decoder, and the `currentVersion` rationale.
- `LibraryArchiveReader.swift`, `ImportPlan.swift`, `ImportReplay.swift` — the
  flag through the parse and the replay.
- `IngestionModel.swift` — `wouldFavorite`, `toggleFavorite`, `setFavorite`,
  `toggleFavoriteSelected`, `applyFavorite`, `canToggleFavorite`,
  `favoriteActionWouldStar`.
- `AtelierRefsApp.swift` — `FavoriteCommand` (⌘D) in the Edit menu.
- `MasonryGridItem.swift` — `FavoriteBadge` + the cell's star layer + the
  accessibility suffix.
- `ItemDetailView.swift` — `ItemDetailActions.setFavorite` + the top-bar star.
- `CollectionView.swift`, `LibrarySearch.swift`, `SpaceView.swift` — the three
  detail hosts wire it.
- `LibrarySearch.swift` — `SearchToken.favorites`, `LibrarySearchQuery.favoritesOnly`,
  `toggleFavoritesFilter`, `FavoritesFilterChip`.
- Tests: `AppFavoritesTests.swift` (new), plus additions to
  `LibraryArchiveTests`, `LibraryArchiveReaderTests`,
  `LibraryArchiveRoundTripTests`, `LibrarySearchModelTests`.

**Docs**
- `.docs/068-backup-portability-plan.md` — two superseded sentences marked, and an
  amendment recording the manifest change.

## Migration notes

**Schema v19. `ALTER TABLE asset ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0`.**

- **What it does:** adds one boolean column to `asset`. Additive and
  constant-defaulted, so it is a plain `ALTER` — no table rebuild, no foreign-key
  dance, no data movement. There is **no back-fill**: nothing could have been a
  favourite before the flag existed, so every existing row reads `false`, which is
  the truth rather than a default standing in for one.
- **How long it takes:** effectively instant on any library size — SQLite records
  an `ALTER TABLE ADD COLUMN` in the schema, it does not rewrite rows.
- **Reversibility:** as with every migration here, the pre-migration snapshot
  (008 · H3) is taken automatically on the first open of a behind-schema library,
  so the pre-v19 database is preserved.
- **What an OLDER build sees:**
  - **Opening a v19 library** — unchanged behaviour: an older build's migrator
    simply has no `v19` to apply and does not consult unknown columns. It will not
    show or write favourites, and it will not damage them.
  - **Reading a v19 ARCHIVE** — it **refuses the whole archive**, with
    `.schemaTooNew("v19")`. This is deliberate and is the reason
    `manifest_version` did not need a bump: the refusal already covers the case,
    and refusing beats a partial import of a contract the build does not
    understand.
  - **Restoring a v19 BACKUP** — the same rule (`RestoreRunner.refusal`, 008 ·
    H5c), unchanged by this work.
- **What THIS build sees from older data:** a pre-v19 archive decodes with
  `is_favorite` absent, read as `false`. A pre-v19 library migrates on open and
  every asset starts unfavourited.
- **Nothing to run manually.** Migration is automatic on open.
