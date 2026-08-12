# 386 — What The Fourth Export Copied

[385](385-the-originals-were-always-the-point.md) shipped the originals export by
building the fourth export from the third. That was the right way to ship it and the
wrong way to leave it: copying `startSite` into `startAssets` put the "ask the flag
first, never the error" cancel rule in three places, and copying
`CollectionSiteExport.rows` — itself already a copy of `ContactSheetExport.rows` —
produced a third public name for one filter, held together by a test asserting the
three still agreed.

A review found sixteen things. Twelve were worth doing. Four were worth writing down
and not doing. One of the four reversed itself when measured, which is the most
interesting thing here.

## 1 · One export controller, not four copies of one

`startSite` and `startAssets` differed in two expressions. Their outcome tail — the
fourteen lines that decide whether a run reports success, cancellation or failure —
was byte-identical, and *also* identical to the moodboard path's. A three-way
duplication of the one place where a cancelled export must not be called a failure.

What is shared is now stated rather than repeated: `runFolderJob` owns the
detached-write shape for both folder exports (cancel flag, destination cleanup,
outcome mapping), and `finish` owns the main-actor tail for all three. `startSite`
also lost a redundant `createDirectory` — both writers create their own.

`ExportControllerTests` landed **before** any of that, deliberately: four entry
points had zero tests, and rewriting ~100 lines of concurrency underneath nothing is
how the cancel rule regresses silently. It covers the invariants a refactor must
preserve — cancel reports `.cancelled` and never `.failed`; a destination folder is
removed only when that run created it; a pre-existing folder with the user's own file
in it survives a cancel; `reportSeq` strictly increments so two identical reports
still trip the toast.

## 2 · Partial success was being reported as success

`Report.Outcome` had three cases, so an export that copied 37 of 40 files reported
`.success` with a count nobody rendered. `ArchiveExportController` had already faced
this exact question and answered it — `ArchiveOutcome.incomplete` exists because
"usable, just not whole; saying 'succeeded' would be a lie and 'failed' would be
worse". Two controllers in one app disagreeing about whether a partial write is a
success is one too many.

`.incomplete` now exists here too, and `finish` promotes `.success` to it in ONE
place, so no export path can forget. It matters more for originals than for anything
else: a moodboard missing a tile looks wrong, while 37 files in Finder look complete.

The skip **reasons** were also being computed and then discarded one line later —
`result.skipped.count`, throwing away a typed enum whose only consumer was `.count`.
A colour swatch that was never exportable and a blob that vanished off disk produced
the same toast, and both read "had no image". `SkipBreakdown` now carries four
buckets, and the toast words them worst-first: a refused write means the folder is
wrong, a missing blob means the library lost bytes, a byte-less ref is simply not
exportable and never was.

## 3 · A refusal that used to be a dead click

`guard !isExporting else { return }` — a silent no-op. The SwiftUI rows disabled
themselves off `isExporting`, but `File ▸ Export Assets…` and the right-click item
could not as cheaply, so those two paths clicked and did nothing at all.

They now report "An export is already running", which fixes the class rather than the
four instances, and the three older exports inherit it.

This turned up a trap worth recording: `publish` resets `isExporting` / `cancelFlag`
/ `task`, so reporting the refusal *through it* would have orphaned the run it was
declining to interrupt — ring frozen, Stop dead, real export finishing invisibly.
Hence `report(_:skipped:)`, which stamps a report without touching run state, and
`refusalDoesNotTearDownTheRunningExport`, which is the test that would have caught it.

## 4 · The writer checks its own invariant now

`AssetFolderWriter` appended a filename to the destination root without checking that
the result stayed inside it. It was safe — `AssetExport.sanitize` maps `/` and `\` to
spaces and trims leading dots, so `"../../etc/passwd"` arrives as `"etc passwd"` —
but that argument lives in a module the package does not import and cannot see, while
the names themselves derive from captured web content (a post title).

A filesystem write does not get to rely on a guarantee it has no way to check, so
`ExportFile.hasSafeName` checks it, `ExportSkip.Reason.unsafeName` reports it, and
`SiteExportWriter` got the same guard.

The first version of that check was `lastPathComponent == filename`, which looks
like it catches every separator case and does not: `("/" as NSString).lastPathComponent`
is `"/"`, so a bare slash compared equal to itself and was accepted. The test matrix
caught it within a minute of being written. It is now three literal conditions,
which are uglier and correct.

## 5 · The measurement that reversed its own recommendation

The review flagged that the `Share ▸` menu resolved its entire payload during menu
construction — a `stat` per selected asset — and proposed deferring it. That proposal
was **refused pending a number**, on the strength of
[383](383-the-poster-that-was-already-there.md), where the obvious-looking
optimization measured 1.1 ms and the real cost was elsewhere.

The number said the opposite. `ShareMenuProbeTests` (opt-in,
`TEST_RUNNER_ATELIER_SHARE_PROBE=1` — plain `ATELIER_…` does not reach the test
runner):

```
selection   resolve   items()   picker()     total
      100   7.4 ms    0.05 ms    3.3 ms    10.7 ms
    1 000  76.0 ms    0.39 ms    0.9 ms    77.3 ms
    5 000 354.5 ms    1.94 ms    4.0 ms   360.5 ms
```

77 ms of synchronous work before a right-click menu could draw. And
`NSSharingServicePicker` — the suspect — was flat at ~1–4 ms and not the problem.

Attribution at n=1000: `appendingPathComponent` 12–25 ms, `AssetExport.filename` +
`sanitize` ~17.5 ms, `fileExists` 4.5–6.9 ms, `UTType(filenameExtension:)` 2.9 ms.
The `UTType` hypothesis was wrong twice over — it is the *cheapest* of the four.
There is no hot call to cache; the cost is spread across URL building and string
sanitizing, both of which a filename genuinely needs.

Which reframed the fix. The menu does not need the payload — it needs to know whether
*one* ref is shareable. `AssetShare.canShare` reads `blobHash` and, only for a
byte-less kind, the decoded content: no URL, no filesystem, no sanitizing. Callers ask
through `contains(where:)`, so it stops at the first hit:

```
n=100    0.019 ms   (was 6.8 ms)
n=1 000  0.004 ms   (was 76.6 ms)
n=5 000  0.006 ms   (was 309.9 ms)
```

Flat, which is the point — it is no longer a function of selection size at all.

`Share ▸` therefore became `Share…`, a click that raises the system sheet, rather than
an inline submenu. Not a preference: `standardShareMenuItem` needs its items at init,
so an inline submenu cannot be made lazy without moving menu items between menus
behind the picker's back. Same system UI, no timing games.

The honest cost of the cheap predicate: `blobHash != nil` says a file *should* be on
disk, not that it is. A selection whose blobs were all reaped since the grid drew them
would offer Share and then have nothing to hand over, so the click does nothing.
Better than making every right-click pay for certainty nobody asked for, and
`cheapPredicateIgnoresDisk` pins it as deliberate.

## 6 · Smaller things

- **One scope rule.** `ExportScope.rows` / `.folderName` replace three spellings of
  one filter; the fork in `CollectionSiteExport` and both pass-throughs are gone. So
  are the two tests that existed only to check the copies still agreed.
- **One request sequence.** `AssetFolderExport.request(...)` — `LibrarySearch` had
  re-implemented filter→plan→request and the two copies had already drifted on the
  folder name. It is a parameter now, because it legitimately differs.
- **`AssetExport.textFallback(for:)`.** The detail page used to reach the text
  fallback by passing `pasteboardEntry` a nil source AND a nil URL so it would fail
  through to it. It asks by name now, and cannot silently disagree with the grid.
- **Progress is coalesced.** The writers call `onProgress` per file and a folder
  export's file count is unbounded; 5,000 files meant 5,000 `Task` allocations and
  5,000 `@Published` invalidations for a ring with ~100 states. `ProgressGate`
  publishes on 1% moves, always lets the first tick and the final `1` through.
- **The menu decision is testable.** `outFlowMenuRows` moved into
  `GridContextMenu.swift`, which exists precisely to keep menu decisions
  "SwiftUI-free so they stay unit-tested without a running view". Tests cover the
  shelf getting neither verb and the stray-separator case.

## Files

**AtelierExport**
- `Assets/AssetFolderWriter.swift` — `ExportFile.hasSafeName`, `.unsafeName` skip
- `Site/SiteExportWriter.swift` — the same guard

**AtelierRefs**
- `ExportController.swift` — `runFolderJob`, `finish`, `SkipBreakdown`,
  `.incomplete`, `report` vs `publish`, `refuseIfBusy`, `progressSink`, `ProgressGate`
- `ExportScope.swift` — new; the one scope rule
- `AssetShare.swift` — `canShare`, `picker(for:)` (was `menuItem`)
- `AssetPasteboard.swift` — `AssetExport.textFallback(for:)`
- `AssetFolderExport.swift` — `request(...)`; `rows` / `folderName` removed
- `CollectionSiteExport.swift`, `ContactSheetExport.swift` — `rows` / `folderName` removed
- `GridContextMenu.swift` — `OutFlowMenuRow`, `outFlowMenuRows`
- `MasonryGridHost.swift` — `ShareHooks`, `presentSharePicker`, lazy Share row
- `ContentView.swift` — `skipSummary`, `.incomplete` toast copy
- `MoodboardExportControls.swift` — checkmark off `didWrite`
- `IngestionModel.swift` — `canShareAny(from:assetIDs:)`
- `CollectionView.swift`, `LibrarySearch.swift` — call sites

**Tests** — `ExportControllerTests` (21, new), `ExportScopeTests` (13, new),
`ShareMenuProbeTests` (2, new, opt-in), plus additions to `AssetFolderWriterTests`,
`AssetShareTests` and `GridContextMenuTests`. Full app suite and 84 package tests
green.

## Migration notes

None — no schema change. `Report.skipped` changed from `Int` to `SkipBreakdown` and
`Report.Outcome` gained a case, both compiler-enforced; the only two consumers were
the toast and the moodboard checkmark.

## Not done

- **⌘C on a large selection pays the same ~77 ms** (`copySelectedToPasteboard` →
  `exportSelection`), measured here and pre-existing. Left alone deliberately: fixing
  it means changing what ⌘C puts on the pasteboard, which is 052 · B1's shipped
  contract with its own tests, and is a separate decision from menu latency.
- **`exportSelection` still walks the whole feed** to resolve a handful of rows.
  Once per gesture, and `IngestionModel.assetIDs(for:)` already does the same walk;
  an index would add invalidation burden on every feed mutation to save microseconds.
- **The probe fails by design when over budget.** It is opt-in, so normal runs are
  unaffected, and `Issue.record` is the only channel that survives — the test target
  is sandboxed (cannot write an arbitrary path) and `xcodebuild` swallows stdout.
- **Still no UI test** that the menu items appear. No UI test target exists, and
  adding one for two menu items is not proportionate; a manual click-through of the
  four entry points is still owed.
