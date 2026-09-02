# 458 — the fate a capture gets

[098](../.docs/098-ios-companion-completion-plan.md)'s second phase, and its spine is two
sentences that were both false on a phone:

> A capture that fails three times is out of the way.

It was not counted three times. It was counted three times *if the process survived long
enough to be told it had failed* — and on a phone the ordinary failure is jetsam, which
tells nobody anything. `attempts` was stamped in `transientFailure`, after the coordinator
reported `.failed`. A kill mid-ingest left the record pending at `attempts: 0`, so the same
capture ran again at the next launch, and the one after that, forever, with no UI anywhere
that could break the loop.

> A capture that is out of the way is in `inbox/failed/`.

`InboxArchive` reads `inbox/` and `inbox/ingested/`. It does not read `failed/`. So on the
phone — a waypoint, not a destination — "out of the way" meant *deleted from the export*,
silently, for a capture whose ORIGINAL BYTES the Mac might well have decoded perfectly.
The one host that must not quarantine was the one host doing it.

Both are fixed here, and they are one change: **who owns the library decides both fates**,
success and failure, which is the question `InboxDrain.Retention` was already there to
answer for one of them.

## The stamp lands before the run

`attempts` now counts attempts STARTED. `prepare` commits the incremented record through
`InboxWriter.rewrite` before the coordinator is handed the input, so the residue of a
process that goes away mid-ingest is a pending record that has already paid for its
attempt. Three interruptions exhaust the budget exactly as three reported failures do.

Two things had to stay true, and both have tests that were already there.

**A cancelled record still spends nothing.** Cancellation is the app being backgrounded,
and a share must not lose a third of its budget to the user switching apps. `resolve` takes
a `restoringTo:` count and puts the stamp back on `.cancelled` / `.none`. Best-effort on
purpose: if the restore itself fails, the record keeps the spent count, which is a lie in
the safe direction — the capture is still whole, still pending, and still has attempts
left. The parameter is optional, so the existing test that drives one `.cancelled` outcome
through `resolve` compiles and passes unchanged, and now covers the "nothing to give back"
path.

**`transientFailure` must not double-count.** It is gone, replaced by three functions that
each do one thing: `spendAttempt` (stamp and commit, before the run), `failed` (the
coordinator lost — is the count on disk the last one?), and `terminalFailure` (it was).
Nothing increments twice because only one of them increments at all.

The cost is one small atomic re-commit per record per pass. That is the price of a bound
that survives the process going away between two lines, and it is paid where the record was
going to be read and decoded anyway.

**What a test can and cannot say about a crash.** A test cannot kill its own process. So
the claim is split: `theStampIsCommittedBeforeTheCoordinatorRuns` reads the record off disk
from INSIDE a live ingest, through the pipeline's existing timing sink, and finds
`attempts: 1` — that is what a jetsam kill leaves, observed at the only instant it exists.
Every other case replays that residue by hand and says so at the line.

## The terminal fate follows the retention policy

Under `.retainForExport` an exhausted record — or one whose attempt could not be committed
at all — stays in the pending set with its count. `DrainSummary.skippedExhausted` counts it,
`prepare` skips it before reading a payload or asking for a coordinator slot, and
`InboxArchive` still sends it. Under `.discardWhenIngested` the Mac quarantines exactly as
092 · S3 shipped, because there IS no consumer downstream of a Mac's inbox.

The rule that does NOT vary is malformed: a `payloadFile` the layout refuses, a `.json`
that will not parse. Those go to `failed/` under both policies, because there is nothing
there for an export to send either. The pair of tests that says which is which is
`retainingDrainQuarantinesTheMalformed` beside
`exhaustedCaptureStaysExportableUnderRetention`.

One existing test changed its expectation, and it is the only behaviour reversal in this
phase: `retainingDrainStillQuarantines` asserted that the phone's drain quarantines an
exhausted capture. It does not any more. Its fixture and its first two passes are
unchanged; the third now reports `skippedExhausted` and leaves the capture where the export
can reach it.

A record that stays pending forever costs one read and one decode per pass. That is the
number the `skippedExhausted` doc gives, and `skippedExhaustedRecordIsNeverRun` asserts the
rest of it: the fixture is a perfectly good PNG that would ingest on sight, and after
exhaustion no ingest is observed, no blob is written and no asset appears.

## The ingested site had never been looked at again

The retaining drain moves a record into `inbox/ingested/` and never looks at it again —
which is right, that is what takes it out of the pending set — and the consequence was that
nothing looked at it EVER again. Two states there are permanent:

- a `.json` that will not decode: counted, never sent, never resolvable;
- a record whose payload is gone from both sites: skipped by the funnel, silently, on every
  single export.

Either one is a wrong number on the Send control for the life of the device, with no
control anywhere that can clear it. So a retaining pass now ends with one walk of that
directory, quarantining exactly those two through the same `quarantineUnparsedRecord` and
`quarantine` paths the pending set uses. It re-ingests nothing — the whole reason a record
is there is that it has already ingested — and it touches no record it can read whose bytes
it can find, which the half-finished-retention case pins from both ends.

`quarantineUnparsedRecord` now looks for the sidecar at both sites, pending first, the same
order and for the same reason `InboxArchive.payloadSite` asks in. `quarantine` gained an
`origin` parameter so the sweep does not need a second copy of the re-encode-or-move
discipline. A discarding drain never enters any of it: an `ingested/` on a Mac is a
directory describing a policy it does not have, and not this drain's to tidy.

## The count on the button and the count in the manifest

`pendingRecords(in:)` dropped an undecodable `.json` with a `try?` and `CaptureExport
.refresh()` counted `.json` FILES. Two numbers, no way for the program to see both, and one
corrupt file made "Send 4" permanent on a phone that could only ever send three.

`InboxArchive.pending(in:)` returns the records AND the count of what would not decode.
`Summary` folds that into `skipped`, names the records the funnel refused in `skippedIDs`,
and keeps `unreadable` separable — `skipped == unreadable + skippedIDs.count` is an
invariant with a test. `pendingRecords(in:)` survives as the records half, which is what the
Mac's `InboxArchiveImportTests` calls.

The phone counts `pending(in:).records.count`. That costs a read and a decode of every
waiting record per activation where it used to be two directory listings; it is bounded by
the number of captures the user has not sent, of ~350-byte files, and it buys a number that
cannot be wrong. The drain's sweep is what stops the corrupt file being there next time;
this is what stops it lying in the meantime.

## One export at a time

`CaptureExport.write` removed a folder of the same NAME, which is the same name only within
the same minute. Send at 18:30 and again at 18:31 and both folders survive in `Caches/`,
each holding a full copy of every capture's bytes. Free while the inbox still owns those
bytes — and the sole owner of them the moment "Clear" deletes the ingested payloads.

`InboxArchive.writeExport(_:layout:under:folderName:appVersion:schemaVersion:now:)` clears
every sibling under the parent, creates the timestamped folder, writes, and returns the
folder with the run. Everything in the parent goes, files included: the directory means
"the current export" and litter it cannot explain is worse than a tidy-up that is total.
Clearing happens BEFORE the write and AFTER the empty-inbox refusal, so a run that finds
nothing to send does not cost the user the folder they may still be holding a share sheet
over.

`folderName` stays in `CaptureExport` — naming is presentation, this package has no locale
— and P3 moves it with the rest of the controller.

## The phone's numbers, and its backup hygiene

`MobileIngest` states two more constants beside its tiers and its width:

- **`maximumPixelArea = 64_000_000`**, wiring in the gate 457 built. 64 MP clears the 48 MP
  the current iPhone sensors produce and a stitched panorama on top, and sits a factor of
  ~67 below the gigapixel headers a hostile page can serve. It is deliberately not derived
  from a memory budget: the peak is a function of `maxConcurrent` too, ImageIO subsamples
  when it makes a thumbnail, and a cap tuned to a bitmap size would refuse the user's own
  photographs to buy a bound the width already provides. Two numbers, two arguments.
- **`-atelier-log-ingest-timing`**, in `TileBodyLog`'s style, logging every ingest rather
  than only a stall — the Mac's sink watches a running app for a regression, and this
  watches a batch that is supposed to be slow. With
  `FixtureLibrary.pendingCaptures` now taking `-seed-pending-captures <n>`, the device
  measurement 098 · finding 3 asks for is a launch argument away.

And `makeDrain` finally runs the backup hygiene the Mac has run since 008 · H2 —
`thumbnails/`, `cache/`, and `Caches/Exports/` — on the platform where a default 5 GB
backup quota makes it matter. `MediaStore.excludeFromBackup(_:)` is the one spelling of
"create it, then flag it"; the export directory has no store to reach it through.

## The sweeps

**Formats.** Every payload in the drain's suite was `CaptureFixtures.png()` or the string
`"not an image"`; every payload in the archive's was a JPEG. A phone shares HEIC out of its
camera roll, PNG and JPEG off the web, photographs taken sideways, and GIFs.
`FixtureImages.PhoneFormat` is that list once — bytes, stored size, display size, MIME —
because two suites in two packages sweep it from the two ends of one handoff and a second
copy is the kind that stops covering a case quietly.

Two answers were worth having in writing:

- **The rotated case disagrees with itself, correctly.** The drain's asset records 30 × 40
  for 40 × 30 of stored pixels, because `ImageMetadata` applies the EXIF transform. The
  manifest records 40 × 30, because `probe` reads the header without decoding. Both are
  right: the file that crosses is the original container, EXIF and all, and the Mac
  re-ingests it through the same pipeline. The manifest's dimensions are a completeness
  check, not the final geometry.
- **The GIF keeps its frames in the blob and loses them in the tiers.** All three frames
  survive in `blobs/` byte for byte and in the archive copy; every thumbnail tier is a
  single-frame JPEG, so the phone's grid draws a still. Nothing here changed that; the
  test asserts it so a later change to the thumbnail stage is a decision.

HEIC skips through `withKnownIssue` where the encoder is unavailable. The convention it
replaces — `guard let … else { return }`, still in `ImageMetadataTests` — is a test that
passes without running.

**Failures.** The branches nothing had ever reached: the archive's copy failure and
manifest-write failure; a record carrying inline base64 with no sidecar, through both of
the drain's no-payload arms and the export's refusal of it; the re-stamp failure under both
policies; the quarantine's move-instead-of-re-encode fallback, forced with a directory at
the destination and VISIBLE because the two paths disagree about the count (the re-encode
says 1, the moved original says 0). `InboxRetirement.Summary.failed` had never been
non-zero in any test and now has four cases. `InboxWriter.rewrite` — which the write-ahead
stamp puts on the hot path — has its two failures.

One of those found something. **A rewrite whose record has vanished re-creates it.** The
doc says `replaceItemAt` is used "because `moveItem` refuses" an existing destination, which
reads as though the call needs one; it does not. Today it is unreachable rather than
harmless — the only caller is the stamp, and `InboxExclusion` serialises retirement and
export against a pass — and if that exclusion ever went, a record retired mid-pass would
come back with a higher count and be exported again, which the archive's dedup collapses on
import. Pinned, so a change to it is a decision.

**Flakes.** `onlyOneCaseDrains` waited up to 0.3 s for a pass to start while
`gateClosesWithoutSuspending`, two suites down, proves the claim is synchronous; it reads
`isDraining` now, with no await between the call and the read. And the three
`LibraryLocationTests` cases that resolve the macOS default root go through
`withoutLeavingDefaultRoot`, which removes `~/Library/Application Support/ref-atelier/`
afterwards if it was not there before and is still empty. The contract is asserted exactly
as it was; a `swift test` run no longer creates a directory in a developer's home.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/InboxDrain.swift` — the write-ahead
  stamp (`spendAttempt`, `failed`, `terminalFailure`, `restoreAttempts`); `Ready` carries
  the stamped record and the count before it; `resolve` gains `restoringTo:`;
  `sweepIngestedSite`; `quarantine` gains an origin; `quarantineUnparsedRecord` looks at
  both sites; `DrainSummary.skippedExhausted`; two header paragraphs.
- `AtelierIngestion/Sources/AtelierIngestion/Media/MediaStore.swift` — `excludeFromBackup(_:)`
  extracted and made public.
- `AtelierIngestion/Tests/AtelierIngestionTests/InboxDrainTests.swift` — 25 new: the stamp
  (5), the two terminal fates and the malformed pair (4), the sweep (7), the format sweep
  (2 parameterised + the GIF), the inline-image arms (2), the un-stampable record (2) and
  the quarantine fallback; `ObservedRecord`; one test's expectation reversed.
- `AtelierArchive/Sources/AtelierArchive/InboxArchive.swift` — `Pending`, `pending(in:)`,
  `Export`, `writeExport(...)`; `Summary.unreadable` / `.skippedIDs` / `.skip(_:)`;
  `write` takes `unreadable:`; two header paragraphs.
- `AtelierArchive/Tests/AtelierArchiveTests/InboxArchiveTests.swift` — 16 new: the
  unreadable count (4), the exhausted capture, the folder lifecycle (5), the failure sweep
  (3), the format sweep (2 parameterised + the GIF); `Rig.exportsParent`,
  `Rig.writeCorruptRecord()`, `Rig.writeExport(folderName:)`.
- `AtelierCapture/Sources/AtelierCaptureTestSupport/FixtureImages.swift` — `Format.gif`,
  `animatedGIF(width:height:frames:)`, `PhoneFormat`.
- `AtelierCapture/Tests/AtelierCaptureTests/InboxRetirementTests.swift` — 4 new, all of
  them `Summary.failed > 0`.
- `AtelierCapture/Tests/AtelierCaptureTests/InboxWriterTests.swift` — 2 new: `rewrite` with
  no staging, `rewrite` with no destination.
- `AtelierLibraryPaths/Tests/AtelierLibraryPathsTests/LibraryMediaPathsTests.swift` — 2 new
  (11 arguments): the MIME → extension table.
- `AtelierLibraryPaths/Tests/AtelierLibraryPathsTests/LibraryLocationTests.swift` —
  `withoutLeavingDefaultRoot`, used by the three cases that resolve the default root.
- `AtelierBrowse/Tests/AtelierBrowseTests/InboxDrainPolicyTests.swift` — the 0.3 s wait
  replaced by the synchronous claim.
- `AtelierRefs/AtelierRefsMobile/MobileIngest.swift` — `maximumPixelArea`,
  `ingestTimingArgument` / `logsIngestTiming` / `logIngestTiming`, the two backup
  exclusions; `makeDrain` wires the cap and the sink.
- `AtelierRefs/AtelierRefsMobile/CaptureExport.swift` — `refresh()` counts decodable
  records; `write` calls `writeExport`; `exportsDirectory`; two header paragraphs.
- `AtelierRefs/AtelierRefsMobile/Debug/FixtureLibrary.swift` — `pendingCaptures` takes
  `-seed-pending-captures <n>`.

`project.pbxproj` is untouched, the Mac app is untouched, and no other app-target file
changed. (`FixtureLibrary` is the one file outside the phase's two named app files: it is
`#if DEBUG`, behind three guards, and P2's device measurement is what needs it.)

## Verification

`swift test --parallel`, before → after:

| package | before | after |
|---|---:|---:|
| AtelierCore | 776 | **776** |
| AtelierCapture | 166 | **172** |
| AtelierLibraryPaths | 30 | **32** |
| AtelierBrowse | 82 | **82** |
| AtelierArchive | 66 | **82** |
| AtelierIngestion | 479 | **502** |
| AtelierServer | 62 | **62** |

All passing. Nothing was dropped; the one test whose expectation reversed is named above
and still runs.

`swift build --triple arm64-apple-ios26.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"`
in AtelierCore, AtelierCapture, AtelierLibraryPaths, AtelierBrowse, AtelierArchive,
AtelierTokens, AtelierIngestion → **Build complete**, all seven.

`xcodebuild build -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'
CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**.

`xcodebuild build-for-testing -scheme AtelierRefsMobile -destination 'platform=iOS
Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO` → **TEST BUILD SUCCEEDED** — the run
that compiles `AtelierRefsMobileUITests`.

`xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'
-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`, run alone, as 457 recommends.
`InboxArchiveImportTests` is the one test that runs both ends of the export and it calls
`InboxArchive.pendingRecords(in:)` + `.write(...)` — which is exactly why both kept their
old shapes.

**One toolchain snag, recorded because the next person will see it.** `swift test` in
`AtelierCore` failed twice with `InternalError(… runner.swift not registered)` and a path
under `.build/arm64-apple-ios/`: the scratch directory was left in an iOS-triple state by
the `swift build --triple` runs (457's row and this one's). Deleting `AtelierCore/.build`
fixed it. Nothing to do with the code; it is a SwiftPM scratch-state bug and it will happen
again to anyone who runs the host suite in a package right after the iOS build.

## What is still NOT covered, stated rather than implied

**Nothing has run on a device, and the two claims that need one are still unrun.** The
jetsam claim — a crash mid-ingest, then a launch, then `attempts` reading 1 — is asserted
here from inside a live ingest on a host, which proves what is ON DISK at that instant and
nothing about what iOS does to the process. And `-atelier-log-ingest-timing` has produced
no numbers: the flag, the sink and the 50-capture seed are plumbing for a measurement that
has not been taken, so `MobileIngest.maxConcurrent = 2` is exactly as unmeasured as 454 left
it. Both are on 098's "left to the user" list and both stay there.

**`skippedExhausted` is counted and never reported.** Both apps' `report(_:)` name
`ingested`, `retrying`, `skippedIncomplete` and `quarantined`; neither says anything about a
record the drain has given up on but kept. The Mac's report is out of this phase's reach by
the rules of the phase, and P4 turns the wording into `DrainSummary.reportLines` for both —
that is where the line belongs. Until then, a phone with an exhausted capture logs a pass
that appears to have done nothing.

**A record retained after a successful ingest carries `attempts: 1`.** That is what
"attempts started" means, and undoing it would be a second atomic re-commit on the phone's
ordinary success path to correct a number whose only reader is the drain, which will never
look at that record again. Argued at `settle`, not tested for, because nothing downstream
reads it.

**The sweep is O(ingested) per pass.** It reads and decodes every record under `ingested/`
on every retaining pass — the same work `InboxArchive.pending(in:)` does on every activation
of the export control, which is the comparison that made it acceptable. On a phone with two
hundred un-cleared captures that is two hundred small reads twice per foreground. Nobody has
measured it on a device either.

**The 64 MP cap has never refused a real image.** Its tests are the package's, over
synthetic headers; no share of a genuine 48 MP HEIC has been through it, and what a user
sees when it refuses is a capture that fails three times and then — on the phone — sits in
the pending set forever, exported to a Mac that will decode it fine. That is the intended
outcome and it has no UI.

**`writeExport` deletes on the phone's behalf and no UI test drives it.** The stale-sibling,
fresh-parent, stray-file and refuse-before-clearing cases are all host tests against a temp
directory. Nothing has watched a real `Caches/Exports/` before and after a second send.

**The export still names its skips only to itself.** `Summary.skippedIDs` exists and the
phone throws it away — `CaptureExport` keeps `exported` and nothing else. Surfacing "3 sent,
1 could not be read" is a screen, and screens are P6's.

## Migration notes

**API additions**, all source-compatible:

- `DrainSummary.skippedExhausted`, and the initializer's new parameter (defaulted, placed
  before `inboxUnreadable:`, so every existing labelled call compiles unchanged). Any
  `report(_:)` that ignores it stays correct — both apps' do today.
- `InboxDrain.resolve(_:outcome:into:restoringTo:)` — the fourth parameter is defaulted to
  `nil`, which means "no stamp to give back". Internal to the package plus `@testable`.
- `InboxArchive.Pending`, `InboxArchive.pending(in:)`, `InboxArchive.Export`,
  `InboxArchive.writeExport(_:layout:under:folderName:appVersion:schemaVersion:now:)`.
  `pendingRecords(in:)` still returns `[InboxRecord]` and still means what it meant.
- `InboxArchive.Summary` gains `unreadable`, `skippedIDs` and two initializer parameters,
  both defaulted and both before `exported:`. `skipped` now INCLUDES `unreadable`, which is
  the only semantic change to an existing field: a caller comparing whole `Summary` values
  built by hand needs the new fields, and one comparing `skipped` gets a number that is now
  right rather than one that was low.
- `MediaStore.excludeFromBackup(_:)` — static, public. `excludeDerivedFromBackup()` is
  unchanged in behaviour and now calls it.
- `FixtureImages.Format.gif`, `FixtureImages.animatedGIF(width:height:frames:)`,
  `FixtureImages.PhoneFormat`. An exhaustive `switch` over `Format` outside the package
  would need the case; none exists.

**Behaviour**, on the phone only:

- An exhausted or un-stampable capture no longer moves to `inbox/failed/` under
  `.retainForExport`. Anything already in `failed/` on a device stays there and is still
  not exported; this changes what happens next, not what happened.
- A record under `inbox/ingested/` that will not decode, or whose payload is gone from both
  sites, is moved to `inbox/failed/` on the next drain. That is a deletion from the export
  set — of a capture the export could never send.
- The Send count is the number of decodable records rather than the number of `.json`
  files. On an inbox with a corrupt file it will drop, once, to the number that was always
  true.
- `Caches/Exports/` holds exactly one folder after a send. A device with abandoned export
  folders loses them on the next send, which is the point.

**On-disk**: no format, no schema and no layout changed. `InboxRecord.attempts` is the same
field with the same encoding; what moved is when it is written.
