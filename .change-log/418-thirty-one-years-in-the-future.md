# 418 — thirty-one years in the future

S6c: the Mac end. [416](416-the-inbox-is-what-the-phone-has-to-send.md) proved the phone
writes a folder the READER parses; [417](417-one-control-that-sends.md) put a button on it.
Neither proves the sentence 092 · S6 actually makes — that a capture made on a phone
becomes an **asset in a Mac library** — and the gap between those two claims is where the
bug was.

## The bug

`InboxRecord` is written with `.secondsSince1970` and has a `makeDecoder()` that says so.
The phone's export read its records with a stock `JSONDecoder`, whose default strategy
reads a bare number as `timeIntervalSinceReferenceDate` — **the same digits, 31 years
later**. Every capture the phone exported was dated 2054.

What makes it worth writing down is how well it hid:

- **Order was correct.** Every date was shifted by the same constant, so the
  capture-time sort 405 asked for produced exactly the right sequence.
- **Dedup was correct.** 18A matches on platform and URL, not on time, so the idempotency
  the whole format exists for was unaffected — a re-import still collapsed.
- **The archive was correct** by every check 416 made. The manifest round-tripped through
  `LibraryArchiveReader` cleanly, because a 2054 date is a perfectly valid date.

It surfaced one layer further on: `created_at` is seeded from the capture's time (407), so
a phone import would pin every capture to the top of Newest, permanently, and a detail
screen would say 2054. **Only a test that ran the phone's producer into the Mac's importer
and then looked at the stored row could see it** — which is precisely the layer S6c was
for, found on its first run.

Fixed by asking for the decoder the format already had. `InboxArchive.pendingRecords(in:)`
now owns "which records, in what order", `CaptureExport` calls it instead of spelling it
out, and `InboxArchiveTests` pins the epoch at the layer it lives on.

## What S6c asserts

Five tests, starting from a real `InboxWriter` inbox with real JPEGs and no library rows
at all — because that is what a phone has (416's finding) — and finishing in
`ArchiveImportController`. Nothing is stubbed between them. The transport is not
exercised: it is a folder move, and it belongs to AirDrop.

| test | the claim |
|---|---|
| `capturesArrive` | three shares become three assets: bytes at the hash the phone computed, kinds, provenance field for field — and the phone still has all three |
| `landsInItsOwnContainer` | the Mac's own Unsorted is untouched; the captures land under a container named for the folder |
| `importingTwiceCollapses` | the re-sent AirDrop: two containers, three assets |
| `overlappingExportsCollapse` | Monday's export and Tuesday's, both imported: three assets, not five |
| `captureTimeSurvives` | Newest on the Mac reads as it did on the phone — the test that failed |

The last two are the ones that count rather than check presence. A provenance field the
phone's writer dropped would leave every capture PRESENT on the Mac — as a second copy —
so presence proves nothing.

`overlappingExportsCollapse` is the design of 417 measured from the far end: the phone
keeps its records after an export, which is only safe if tomorrow's archive containing
today's captures is a no-op. It is.

## A wart found and deliberately not fixed

Importing the same phone archive twice produces a second container named
**"Atelier 2026-08-17 2"** — `Validation.uniqueCollectionName` strips a trailing integer
before numbering (043 · 2c), so the export's time of day is read as a copy index and
discarded. Cosmetic, no data implication, and a property of a naming rule EVERY collection
in the app shares: a user's "Refs 2005" duplicates to "Refs 2" today.

S6c therefore asserts what the destination rule actually promises — two containers, not
one clobbered — and does not pin the wart, so fixing the rule later doesn't have to come
back through this file.

## A flake caught on the way past

Running the iOS UI bundle three times in a row for this change turned
`testSendingPresentsAShareSheetAndKeepsTheCaptures` red once: *sending produced no share
sheet*. Not the app — the run took 396s with simulator launch failures in the log, and the
sheet's wait was `collectionViews` for 20s and THEN `Copy` for 5, so the second anchor got
five seconds on a machine where the first was never going to appear.

Rewritten as one predicate polling every anchor at once — the activity grid, a Copy
activity, and the app's own control going unreachable behind a modal — with 90s to do it
in. Presenting a share sheet means discovering every share extension installed, and a slow
machine must not read as a broken app. On a warm simulator the whole test now takes 13s;
the budget is there for the cold one.

## Files

    AtelierArchive/Sources/AtelierArchive/       `pendingRecords(in:)` — the decoder fix;
      InboxArchive.swift                         `collectionName` public
    AtelierRefs/AtelierRefsMobile/               asks for the order by name
      CaptureExport.swift
    AtelierRefs/AtelierRefsTests/                5 tests, phone → archive → Mac
      InboxArchiveImportTests.swift
    AtelierArchive/Tests/AtelierArchiveTests/    the epoch, pinned where it lives
      InboxArchiveTests.swift
    AtelierRefs/AtelierRefsMobileUITests/        the share-sheet wait, de-flaked
      ExportUITests.swift
    .docs/092-ios-companion-plan.md              S6 status: three slices, both findings

## Migration notes

**Any archive already written by a build before this one carries 2054 dates.** There is
none outside this branch's simulator runs. If one exists, its captures import with wrong
`created_at`; re-exporting from the phone (the records were never deleted — 417) and
re-importing fixes the dates only for NEW assets, since a dedup hit does not rewrite the
row it matched. Deleting the mis-dated import and re-importing is the reliable repair.

**S6 is complete.** S6a moved the format into a package both platforms link (415), S6b
wrote the phone's half (416, 417), S6c proves the two halves meet. What remains unproven
is the transport: a simulator has no AirDrop, so folder-over-AirDrop is still stated
rather than demonstrated (417).
