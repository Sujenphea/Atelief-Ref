# 332 — Two copies of the same picture

Feature 012 · I5 — the **near-duplicate review surface**. The library can now show
you groups of near-identical images side by side and let you delete the copy you
don't want. It proposes; you dispose.

## Summary

`PerceptualHash` (012 · I1) has been quietly hashing every analysed image for a
while and nothing read the result. This is the reader: a File ▸ **Review
Duplicates…** sheet listing Hamming-distance clusters, each with its copies, their
dimensions, size on disk and capture date, and one action per copy — delete *this*
one.

Three constraints shaped everything, and each is enforced somewhere a test can see
it:

**It never merges and never deletes on its own.** There is no "clean up
automatically", no pre-ticked keep-the-biggest, no bulk apply. Every removal is a
click on a specific image, confirmed in the sheet.

**A delete from here is an ordinary delete.** It is handed to
`IngestionModel.deleteReviewedDuplicates(assetIDs:)`, which lands on the very same
private `deleteRecoverably(assetIDs:)` the grid's confirmed delete now also uses —
so the pre-destructive snapshot, the in-DB recoverable backup, the ⌘Z undo
registration and the deferred blob reap are identical. There is deliberately no
second delete path in this feature; the shared implementation was extracted out of
`confirmPendingDeletion()` rather than copied.

**A group of one stops existing.** As copies are deleted a cluster shrinks, and
the moment it is down to a single member it is removed from the list rather than
shown with a disabled button. The one thing this surface must never do is invite
you to delete the last remaining copy of something.

## The grouping

`NearDuplicateClustering` (AtelierIngestion, pure — hashes in, clusters out, no
database and no UI) makes three judgement calls, all documented at the call site:

**Threshold: 5 of 64 bits.** `PerceptualHash` names ≤10 as the usual near-duplicate
cutoff; that is tuned for a *browse* feature where an over-eager match costs a
glance. Here the action attached to a group is a delete, so the error directions
are not symmetric. A re-encode / resize / quality-drop — exactly what byte-exact
dedup misses — moves a dHash 0–4 bits, so 5 covers the real cases with a bit to
spare; and only ~8.4e6 of the 2^64 signatures lie within 5 bits of any given one
(~4.6e-13 of the space), so even a 100k-image library expects ~0.002 accidental
pairings. At 10 bits that figure is ~55 unrelated images offered up for deletion.
It is a parameter, not a baked-in constant, so it can be re-tuned against measured
data later.

**Complete linkage, so A~B, B~C, A≁C is TWO clusters, not one.** Single-linkage
transitive closure chains, and a chained cluster walks arbitrarily far from where
it started — which is precisely how a review surface ends up proposing that you
delete an unrelated image. A group is emitted only when *every* pair inside it is
within the threshold, which means one asset can legitimately appear in two groups.
Both honest pairs are shown rather than merged into a claim the hashes don't
support; deleting the shared member simply empties both.

**The dHash blind spots are excluded outright.** Every solid (or smoothly
monotone) image reduces to hash `0` and its mirror to `UInt64.max` — those values
are the *absence* of evidence, not evidence of similarity, and grouping on them
would collect every flat image in the library into one enormous "duplicate"
cluster. Both are dropped before clustering. Telling genuinely-identical flats
apart needs the colour signature and is out of scope here.

Candidate pairs are found by banding (multi-index hashing): the 64 bits are split
into `threshold + 1` disjoint bands and bucketed, so by the pigeonhole principle
any true pair must match exactly on at least one band. Every proposal is then
verified with a real Hamming distance. Cost scales with the number of
near-duplicate *pairs*, not with n², and a test cross-checks that banding finds
every pair an O(n²) sweep would.

## Deliberately not in this change

- **No suppression memory.** Closing the sheet doesn't hide a group; the next scan
  proposes it again. A suppression table is real scope (including a rule for what
  an analyser-version bump does to it) and a group silently hidden by state the
  user can't see is worse than one that reappears.
- **No membership merging.** Two overlapping groups stay two groups.
- **No migration.** The schema stays at v18 — `asset_analysis.phash` has been there
  since v7 and this only reads it.

## Behaviour worth knowing

An undone delete restores the *asset* but not its analysis row (derived data; it
cascaded away and the recoverable backup deliberately doesn't carry it), so a
just-restored copy is absent from the list until the idle backfill re-hashes it.
Staying quiet about an image whose signature we no longer hold is the right way
round: the alternative is proposing a delete on grouping we can't currently
justify. Pinned by a test.

## Files changed

**New**

- `AtelierIngestion/Sources/AtelierIngestion/Analysis/NearDuplicateClustering.swift`
  — `HashedAsset`, `NearDuplicateCluster`, and the pure clustering + shrink rules.
- `AtelierIngestion/Tests/AtelierIngestionTests/NearDuplicateClusteringTests.swift`
  — 23 tests: the threshold boundary either side, transitivity, chaining refusal,
  degenerate exclusion, ordering, determinism, band layout, banding-vs-brute-force,
  and the shrink/retain rules.
- `AtelierCore/Tests/AtelierCoreTests/ServicesDuplicateHashesTests.swift` — 8 tests
  over the inventory read (deleted / un-hashed / media-less / still-downloading all
  absent; ordering; signed round-trip).
- `AtelierRefs/AtelierRefs/DuplicateReviewController.swift` — reads, groups off the
  main actor, hydrates only clustered assets, forgets a deleted copy.
- `AtelierRefs/AtelierRefs/DuplicateReviewSheet.swift` — the surface.
- `AtelierRefs/AtelierRefsTests/DuplicateReviewControllerTests.swift` — 14 tests
  over a real temp library: delete routes through the recoverable path and
  undo/redo round-trips, a shrunk group disappears, a vanished asset is never
  proposed.

**Modified**

- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `perceptualHashes()`,
  the whole-library inventory of live analysed signatures.
- `AtelierCore/Sources/AtelierCore/Services/ServiceTypes.swift` — `AssetPerceptualHash`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `showDuplicates`;
  `deleteReviewedDuplicates(assetIDs:)`; the recoverable delete extracted out of
  `confirmPendingDeletion()` into a shared `deleteRecoverably(assetIDs:)`.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — the sheet, on the main window so
  ⌘Z reaches the same undo stack.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — File ▸ Review Duplicates….

## Migration notes

**None.** No schema change; the migrator stays at v18 and
`Migrator.registeredIdentifiers` is untouched. No data is written by this feature —
the only write it can cause is a delete the user asked for, through the existing
path.
