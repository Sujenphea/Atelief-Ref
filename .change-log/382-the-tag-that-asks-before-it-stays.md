# 382 — The Tag That Asks Before It Stays

012's I3 — suggested tags — has been "rendering only" since the schema reserved
`TagSource.agent` in v1. The sparkle chip was drawn at two sites and *nothing in
the tree ever produced one*, so the half that makes suggest-and-confirm real —
accept, dismiss, and a dismissal that stays dismissed — had nothing to act on.

Both halves ship here: an on-device classifier that proposes tags, and the
confirmation semantics around them. Schema is **v22**.

## 1 · A refusal is a fact, so it gets a row

The design question 012 flagged and left open was the only hard one: a dismissed
suggestion must survive an analyzer/model version bump. It cannot be handled by
deleting the `asset_tag` row, because the *image* is what produced the label and
the image does not change when the user says no — the next pass recomputes it and
puts it straight back. A dismissal that quietly undoes itself two idle passes
later is worse than one that never worked.

So `tag_suppression (asset_id, tag_name, suppressed_at)` records the refusal
itself. Keyed on the **name**, not on a `tag.id`: dismissing unlinks the agent
tag, and a tag row nothing points at is not kept alive to satisfy a foreign key —
an FK would have to either resurrect the tag or cascade the refusal away, which is
the exact memory loss the table exists to prevent. It CASCADEs on `asset_id` like
every other per-asset derived table, and carries no secondary index: every read is
"what has this asset refused", which the composite PK already serves.

`ServicesSuggestionsTests.suppressionSurvivesVersionBump` is the test this feature
is for — suggester v2 proposes the identical labels over the identical bytes, and
the refused one does not come back.

## 2 · Accept cannot be a flip of `tag.source`

012 words accepting as "source flips `.agent` → `.user`". That reading is wrong
against the schema, and the correction is worth recording because the wrong
version would have looked like it worked.

`tag.source` lives on the **tag row**, which `applyTag` finds-or-creates by
`(name, source)` — so one `.agent` "poster" row is shared by every asset it was
ever suggested for. Editing it in place would confirm the suggestion on every
other asset at once, including ones the user has never opened. Accept is therefore
an unlink-and-re-apply, per asset, which is the granularity a confirmation
actually has. `acceptDoesNotPromoteSiblings` pins it.

The cost is that an accepted tag no longer records that a machine proposed it
first. That provenance would need a column on the `asset_tag` join, and it buys
nothing actionable: once confirmed, it is the user's tag.

## 3 · Its own version counter, not the analyzer's

`suggest_version` is a new column on `asset_analysis`, deliberately separate from
`analyzer_version`. Folding classification into `AssetAnalyzer` would have shared
its single decode — the obvious efficiency, and the wrong trade. `analyzer_version`
gates OCR, colors and the perceptual hash **together**, so a change to the tag
model would re-OCR the entire library to deliver it, and the two things change on
completely different schedules.

The consequence is one extra decode per asset, paid once per suggester version on
an idle queue. `upsertAnalysis` now explicitly CARRIES `suggest_version` across a
re-analysis (while continuing to clear `colors_palette_version`, which new
`colors` genuinely invalidate) — without that, every analyzer bump would silently
become a suggester bump and the split would be decorative.

`assetsNeedingSuggestions` is an INNER join to `asset_analysis`, not a LEFT one:
the marker lives on the analysis row, so an asset without one could be classified
but never marked, and would be re-classified on every pass forever.

## 4 · Agent tags left the search vocabulary

`tagVocabulary` returned both sources, contradicting 012's settled posture that
unconfirmed guesses are "NOT filter targets and NOT in the token vocabulary". It
now filters to `.user`. This changed no behaviour when it landed — nothing
produced an agent tag yet — which is precisely why it was worth closing before the
producer existed rather than after.

## 5 · Two chips in one row

Suggestions render inline in the existing Tags flow rather than in a separate
section: a suggestion is an offer to complete the list you are already looking at,
and a second section would ask you to look in two places to see what an item is
tagged. The ✦ and the interaction keep them apart — click the body to keep it, ✕
to refuse it for good ("Dismiss — don't suggest this again", not "Remove").

The accept is an `.onTapGesture`, not a `Button` wrapper: the ✕ inside the chip is
itself a Button, and a Button nested in another Button's *label* never receives
the click. A tap gesture on the ancestor loses to a real Button child — which is
exactly the precedence needed.

`AssetTagsStore.remove` now branches on source, so the same ✕ deletes a user tag
and *refuses* an agent one. All three detail hosts (collection grid, search,
space board) go through that store, so accept needed one new closure and dismiss
needed none.

## 6 · Where it runs

`SuggestionBackfill` is the fifth pass in `AnalysisCoordinator`, and it runs
**last** and **bounded** (5 × 20 assets per pass). It is the second expensive
queue — a decode plus a Vision model per asset — and it feeds nothing downstream:
the semantic corpus is title / name / note / OCR, not tags. Running it earlier
would let a first-launch backlog starve queues whose output people are waiting to
see, which is the failure the color pass was moved to first to avoid.

The embedding block became an `if` instead of a `guard … return`, so suggestions
still run on a machine with no sentence-embedding model installed.

## 7 · The policy, and what it refuses

`VNClassifyImageRequest` (the legacy `VN*` API, matching `VisionTextRecognizer` —
Vision's newer Swift API is async and would push the non-`Sendable` `CGImage`
across an `await`, which that adapter's header explains it chose a sync signature
to avoid). Labels are gated by `hasMinimumRecall(0.01, forPrecision: 0.9)`, then
`TagSuggestion.select` caps at **three**, most confident first.

Vision returns its whole taxonomy on every image, so the gate is load-bearing
rather than decorative — `precisionGateFilters` asserts that demanding an
impossible precision returns strictly fewer labels than demanding none. Ordering
ties break on name so the result is TOTAL: without that, two runs over one image
could propose a different three and the chips would shuffle under the pointer.

## 8 · A refusal is user intent, so it rides the backup

Found while reviewing the above, and fixed here rather than filed: the archive
manifest carried notes, favorites and `archived_at` under an explicit rule — *"it
is user intent, not derived data; nothing can recompute it"* — and a dismissal
passes that test exactly. Without it, restoring a backup re-suggests every label
the user has ever refused on the first idle pass after the import: the failure
this feature exists to prevent, arrived at by a different road, surfacing days
later as "the tags I deleted keep coming back".

`suppressed_tags` is an optional `[String]` on the manifest's asset entry —
optional on decode like `is_favorite` and `archived_at`, so archives written
before v22 still read, and omitted entirely when empty, which is nearly always.
It replays through `dismissSuggestion` (the shipped funnel, per the archive's own
discipline), after the tags, additively and idempotently. Only names travel; the
replay stamps its own `suppressed_at`, as it does for every other write.

`suppressionsRoundTrip` covers it end to end over two real libraries, with the
negative half — nothing else picks up a refusal — because a replay layer that
suppressed every tag it saw would pass the positive assertion alone.

## 9 · The adapter's own test cannot run with its siblings

Worth recording because it looked like a hang in my own code and was not.

A synchronous `VNClassifyImageRequest.perform` **deadlocks AtelierIngestion's
parallel test bundle**. Measured four ways: without the suite, 418 tests in 2.1 s
green; with it, the whole process wedges after ~1.3 s with every suite frozen
mid-flight and CPU time flat — no failure, no timeout, just stop; the suite alone,
2 tests in 0.15 s green; marked `.serialized`, still wedged, which rules out its
own two tests racing each other. `VisionTextRecognizer` performs synchronously in
the same bundle and has never done this, so it is the classification request
specifically, not Vision and not the sync seam.

The production path is the shape the seam was built for and is unaffected — one
asset at a time from an app process on the coordinator's `.background` task, not
forty suites deep on the cooperative pool — and the app target's full test run is
green. So the suite is opt-in behind `ATELIER_VISION_CLASSIFY_TESTS=1`, with the
measurement written into its header. Everything that is our logic rather than
Apple's is covered through the fake seam and runs normally.

## Files

**AtelierCore**
- `Persistence/Migrator.swift` — v22: `tag_suppression` + `asset_analysis.suggest_version`
- `Domain/TagSuppression.swift`, `Persistence/TagSuppression+GRDB.swift` — new
- `Domain/AssetAnalysis.swift` — `suggestVersion`
- `Services/AppServices.swift` — `assetsNeedingSuggestions`, `recordSuggestions`,
  `acceptSuggestion`, `dismissSuggestion`, `unsuppressTag`, `suppressedTagNames`;
  `linkTag`/`unlinkTag` extracted and shared with `applyTag`/`removeTag`;
  `tagVocabulary` filtered to `.user`; `upsertAnalysis` preserves the marker

**AtelierIngestion**
- `Analysis/TagSuggestion.swift`, `Analysis/VisionImageClassifier.swift`,
  `Analysis/SuggestionBackfill.swift` — new

**AtelierRefs**
- `AnalysisCoordinator.swift` — the fifth pass
- `AssetTagsStore.swift` — `accept`, and `remove` branching on source
- `ItemDetailView.swift` — `SuggestionChip`, `onAcceptTag` plumbed through,
  `DetailChip.removeHelp`
- `CollectionView.swift` / `LibrarySearch.swift` / `SpaceView.swift` — one closure each
- `LibraryArchive.swift` / `LibraryArchiveWriter.swift` / `LibraryArchiveReader.swift` /
  `ImportPlan.swift` / `ImportReplay.swift` — `suppressed_tags` through the backup path

**Tests** — `ServicesSuggestionsTests` (19), `MigrationV22Tests` (6),
`TagSuggestionTests` (8), `SuggestionBackfillTests` (8),
`AssetTagsStoreSuggestionsTests` (4), `VisionImageClassifierTests` (2, opt-in),
`LibraryArchiveRoundTripTests` (+1); `ServicesTagSearchTests` (+2, one rewritten)
and `AssetReadSurfaceTests` updated.

`AssetReadSurfaceTests` failed on the new read exactly as designed and was given
its stated reason: archived items ARE classified, so unarchiving one does not show
a bare item whose chips arrive an idle pass later.

## Migration notes

v22 is additive and empty on upgrade — nothing has ever been suggested, so nothing
can have been refused. `suggest_version` is NULL for every existing row, which
means "no suggester has looked here yet", so the backfill picks the library up on
the next idle pass. No table rebuild, no data migration, nothing to undo.

## Not done

- **No library-wide never-suggest list.** Suppression is per (asset, name), so
  refusing a generic label like "text" is a per-item action. If that chafes, the
  answer is a second, coarser table — not a widening of this one.
- **Images only.** Video suggestions would need the poster-frame path 012 already
  defers for OCR.
- **No undo affordance for a dismissal.** `unsuppressTag` exists and is tested;
  nothing in the UI calls it yet. A restore is the only way back today, and it
  only restores what the archive holds.

## Also in this change

`.docs/feature-todo/018-canvas-direct-manipulation.md` → `.docs/088-…`. All seven
of its phases are closed (C7 by measurement), so it left the backlog for the flat
set. It renumbered rather than keeping 018, which the flat set had already spent
on `018-bulk-import-plan.md`; `086`'s link was updated, and both the moved doc and
`086` carry a note saying so. Entries 365 and 381 still call it 018 — they were
true when written and were left alone.
