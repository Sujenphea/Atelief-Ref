# 411 — recognised by their contents

The other half of [410](410-a-cover-almost-nobody-set.md): the read exists, and now the
switcher's rows use it. 093 § 2 asked for this in one sentence — *"rows carry a thumbnail
rather than a bare name, borrowing the idea from the Mac's Home gallery of cover cards: a
reference library's collections are recognised by their contents, not their spelling"* —
and [409](409-the-rhythm-that-decomposed.md) shipped without it and said so.

## Three files, and each decides exactly one thing

**`BrowseLibrary.collectionCovers(for:)`** turns ids into URLs and nothing else. The rule
about *which* asset represents a collection is `AppServices`' (410), stated once, so the
phone's sheet and the Mac's gallery cannot pick different pictures for the same folder; the
seam's own contribution is the tier — the 512 grid tier, via a new
`gridThumbnailURL(forHash:)` that `gridThumbnailURL(for:)` now routes through, so a cover
and a tile of the same asset resolve to the same path. That matters more than it looks:
`ThumbnailCache` is keyed by `path#pixels`, so one path is one decode shared between the
sheet and the grid, and two spellings of it would have been two.

Unstat'ed, like the grid tile's, and for the reason stated there.

**`LibraryStore`** decides *when*. Covers load after `phase = .ready`, not before: the grid
is what the user launched for and needs none of them, and gating first paint on a read only
the sheet consumes spends launch latency on a screen nobody has opened. `refreshCovers()`
is private, non-throwing, and never clears — a failed cover read leaves the previous map
alone and the affected rows fall back to folders. It is decoration for a sheet and must not
be able to take out a library, which a failed *tree* read legitimately can.

It re-runs wherever the tree does: at bootstrap, and in `refreshCollections()`, which the
root grid already calls on every load — so a collection whose first item arrived from the
Mac since launch gets its picture on the next visit rather than the next cold start.

**`CollectionSwitcher`** decides how big the square is and what stands in when there is
nothing to show. 36pt, deliberately under the 44pt touch minimum: the minimum is the row's
HIT area, which the whole row already satisfies (093 § 5), and a thumbnail sized to it
would push the outline's indentation off a 390pt screen by the second level of nesting.

The square is drawn **whether or not there is a picture** — an absent cover gets a folder
glyph on the same `mediaBackdrop` ground. A name column that shifts sideways depending on
whether a folder happens to contain an image reads as two lists interleaved. And `nil` here
means *empty*, not *broken*: 410 keeps a collection with no byte-backed member out of the
map entirely, so "no entry" is a fact about the collection rather than a file that failed
to load, and the folder glyph is the honest drawing of it.

`listRowInsets` is deliberately not set, with a comment saying so — the outline spends its
per-level indentation out of the row's leading inset, so overriding it flattens the exact
nesting the tree is there to show.

## Verification

Three tests at the browse seam, in `AtelierBrowseTests` — the layer where `swift test` can
still reach, since none of the three files above the seam are testable without a phone:

| the rule | the test |
|---|---|
| no cover set ⇒ the newest member's 512-tier URL | `coversFallBackToNewestMember` |
| an empty collection is absent (⇒ the row draws a folder) | `emptyCollectionHasNoCover` |
| an archived newest member is not the cover | `archivedMemberIsNotACover` |

The first asserts the URL against `gridThumbnailURL(forHash:)` rather than against a
hand-spelled path, which is what pins the shared-decode property rather than merely the
directory.

## Files

    AtelierBrowse/Sources/AtelierBrowse/       `collectionCovers(for:)` → `[UUID: URL]`;
      BrowseLibrary.swift                      new `gridThumbnailURL(forHash:)`, which
                                               `gridThumbnailURL(for:)` now routes through

    AtelierBrowse/Tests/AtelierBrowseTests/    +3 tests over the covers seam
      BrowseLibraryTests.swift

    AtelierRefs/AtelierRefsMobile/             `collectionCovers` state, loaded after
      LibraryStore.swift                       `.ready` and on every tree refresh by a
                                               private, non-throwing `refreshCovers()`

    AtelierRefs/AtelierRefsMobile/             rows draw a 36pt cover or a folder; the
      CollectionSwitcher.swift                 header's "no thumbnail yet" note is gone
                                               because the thing it deferred is here

    AtelierRefs/AtelierRefsMobile/             passes `store.collectionCovers` to the sheet
      ContentView.swift

## Migration notes

None — read-only browse, no schema, no stored preference. `CollectionSwitcher` gained a
required `covers:` parameter; it has one call site, in `ContentView`.
