# 457 — one spelling of each rule

[098](../.docs/098-ios-companion-completion-plan.md) is the companion's completion pass,
six phases, and this is the first: the package foundation the other five stand on. It
carries finding 2's move (the SSRF guard), finding 3's gate and comments, finding 8's
writer, finding 10's seam, finding 12's consolidation and extractor, the stale manifests,
and the DRY batch that lives in packages. No app target changed. Every app target and the
UI-test bundle still compile, because every API this phase touched kept its old entry
point — the app call sites move in P2 and P3.

The theme, once the work was done, turned out to be the title. Almost every item was a
rule that had been spelled more than once and agreed by inspection: the move that clears
its destination (three times), trim-or-nil (four), the join to `library.sqlite` (three),
the retention move order (the drain plus two fixtures that promised to mirror it), the
JPEG builder (two suites, verbatim), the gate a test parks a task on (three shapes). None
of the copies had drifted. That is not the argument for leaving them; it is the argument
that nothing would have said so when one did.

## The layout owns composition, and now the operations too

`InboxLayout` already said "composition lives here or it drifts" and provided only the
record mirrors — `failedRecordURL`, `sentRecordURL`, `ingestedRecordURL`. The payload
half was composed by hand at every call site, as `failedURL(named:
InboxLayout.payloadFileName(for: record.id))`, which is the guarded resolver for a name
that arrived from disk being asked about a name derived from an id. It gains
`failedPayloadURL(for:)`, `sentPayloadURL(for:)` and `ingestedPayloadURL(for:)`, non-
optional because an id-derived name has nothing for the guard to refuse; `InboxDrain`,
`InboxRetirement` and `InboxArchive.payloadSite` read them.

The three filesystem primitives every mover of inbox files had spelled — `InboxDrain.move`
and `InboxRetirement.move` byte-identical, `InboxRetirement.remove` beside them, and the
lazy-mkdir flag as two methods on `InboxDrain.Pass` and one local in `retire` — are
`InboxLayout.replacingMove(_:to:)`, `removeIfPresent(_:)` and `LazyDirectory`. The file's
header said "creates nothing, with three marked exceptions"; it now says which exceptions
and why they are there rather than in a fourth type: the operation that consumes a path
belongs beside the path. `LazyDirectory` is a value with a `mutating prepare()` so "once"
means once per pass, which is what lets `Pass` stay `inout` state that two passes never
share. `Pass` now takes the layout (`Pass(layout:)`), since its two directories are
`LazyDirectory`s and know their URL.

**The retention order is a plan, stated once.** `InboxLayoutTests` and
`InboxArchiveTests` each hand-rolled the two moves a retaining drain makes — record first,
then payload — with a comment promising `InboxDrainTests` pinned the order. It did, for
the drain; a change to the drain would have left both fixtures green and both suites
lying. The fixtures cannot import `AtelierIngestion` (this package is what the share
extension links), so the honest DRY move was to put the ORDER where both can reach it:
`InboxLayout.retentionMoves(for:) -> [FileMove]`, a list because a list carries order and
two named properties would not, each move tagged `.record` or `.payload` so a fixture can
apply its own rules (skip an absent payload, stop after the record for the crash case)
without index arithmetic. `InboxDrain.retain` executes the list and stops at the first
failure; `InboxFixtures.retain` executes the same list with `moveItem`. The leak-beats-
wedge argument moved with it, and the drain's doc now points at it rather than restating
it.

## One trim-or-nil, one open

`TextRules.nonBlank` in `AtelierCore` replaces `ShareCapture.normalizedTitle`,
`PageHarvest.nonBlank`, `BrowseFormat.nonBlank`'s body and `SearchRules.normalizeText`'s.
`BrowseFormat.nonBlank` stays as a forwarding entry point because the phone's tiles and
detail screen call it by that name; it decides nothing. `LibraryLocation.overrideValue`
keeps its inline copy and says why in one line: that package has no dependencies by
charter and a leaf cannot import the rule.

`AppServices.open(libraryRoot:)` and `databaseURL(in:)` are the one composition of
`AtelierCore.databaseFileName` with a root. `BrowseLibrary.init(root:)` and the two test
rigs that had spelled the join use them; `LibraryStore` and `FixtureLibrary` in the phone
app still spell it and move in P3.

## The guard moves, and a typealias has one wrinkle

`SSRFGuard` and `SSRFError` are `AtelierCapture` types now, Foundation + Network only,
with their tests moved unchanged apart from the module they import. `AtelierIngestion`
typealiases both the way it does `ContentHasher`, so `PageResolver`, `RemoteImageFetcher`
and every test keep the name they use and there is exactly one guard in the program. The
extension's fetch adopts it in P5; nothing about the Mac's fetches changed.

The wrinkle: a typealias is enough everywhere except in a **default argument**. Both
resolvers default a parameter to `SSRFGuard()`, and Swift refuses to evaluate an
initializer in a default-argument position unless the defining module is imported by
that file by name — the alias does not count. Two files gained `import AtelierCapture`
with a comment saying that is why.

## The pixel-area gate

`IngestPipeline` takes `maximumPixelArea: Int?` beside `tiers`, nil by default and so nil
on the Mac. It is checked in `storeBytesBlobFirst` immediately after `extractMetadata`
— which reads dimensions from the container's header — and before the blob write, the
tier check and any decode, so an image over the cap costs a hash and a header read and
leaves nothing on disk. The refusal is `IngestError.pixelAreaExceeded(pixels:limit:)`,
and the tests assert what a refusal leaves behind rather than only what it returns: a
gate placed one line lower would pass a `.failed` test and leak a blob per hostile share.

Two details the plan did not ask for. The product is computed with
`multipliedReportingOverflow`, because the dimensions come out of a header another
process wrote and 2³² × 2³² is exactly the input a cap is for; an overflow is reported
as `Int.max`, not the wrapped value. And a video's track size is gated the same way as an
image's, since the cap is a fact about what this host will hold decoded. The phone wires
its number in P2 (`MobileIngest.makeDrain`), beside its narrowed tiers.

No exhaustive `switch` over `IngestError` exists anywhere in the tree — the Mac app never
names the type — so the new case broke nothing and no app file was touched.

## The comments, and the one that was not false

`InboxDrain.swift:573` ("the bytes never leave disk") and `DirectInputFactories.swift:181`
("what it decides is that the bytes stay on disk") were false: `IngestPipeline
.storeBytesBlobFirst` does `Data(contentsOf:)` on a `.fileURL`, hashes that `Data` and
stores the blob from it. Both now say so, and say what `.fileURL` does buy — the drain
holds no copy of its own beside the pipeline's, and the shape is what a streaming stage
would consume unchanged.

`IngestInput.swift:12-14`, the third in the plan's list, was **not** false. It already
said "the pipeline reads both into a single `Data`"; what was stale was the parenthetical
"(images are modest)", written before the inbox accepted 64 MiB payloads. It now names
the line the read happens at and the cap that bounds it. `MobileIngest.swift:85-92` is
the fourth and is P2's.

## The writer's floor

`InboxWriter` refuses a zero-byte payload with `InboxWriteError.payloadEmpty`, for both
the `.data` and the file shape, at the same moment the cap is checked — before the inbox
directory is created. The case has no `underlying` for the reason `payloadTooLarge` has
none: nothing was caught. An empty payload is not a media-less capture (that is spelled by
passing no payload, and a test now pins that the two are still distinct); it is a
provider that handed over nothing and called it an image, and a record for it would be
complete on sight, ingest-fail three times and be unprobeable at export — both wedges from
one empty file. The extension's card already collapses every writer failure into one
sentence, so nothing in the extension changed.

## The seam takes a bundle

`LibraryLocation.appGroupIdentifier(bundle: Bundle = .main)` reads the key;
`appGroupIdentifier(rawValue:)` loses its default and becomes the pure parse it always
was underneath; `defaultRoot(bundle: Bundle = .main)` threads it through to the iOS branch
and does not consult it on macOS. Every existing call — `appGroupIdentifier()`,
`defaultRoot()`, `resolvedRoot()` — resolves to the same thing it did, which is pinned:
on the test host `.main` is the XCTest runner and carries no key, and the default and the
explicit `.main` read must throw the same typed error. The tests write a bundle to a temp
directory (a directory with an `Info.plist` is one) and read a present, an absent and a
blank key out of it. `Tier2ShareUITests` passes its own bundle in P6.

The file's header said it lived in `AtelierCapture`. It has lived in `AtelierLibraryPaths`
since 448. Corrected, along with the two "the phone never drains" paragraphs in
`InboxRetirement` and `InboxArchive` that 454 made false.

## The extractor

`PageExtractor.twitter` derived a handle from the first path segment of ANY X URL, so
sharing the feed recorded `@home` and a profile page recorded its owner as the author of
a capture with no post. A handle now exists only on a status page, and `i` — X's reserved
namespace, as in `/i/status/<id>` and `/i/bookmarks` — is never one even there. Negatives
for `/home`, `/i/bookmarks`, `/explore`, a profile, `with_replies`, a search and the
root; `/i/status/` keeps its tweet id and yields no handle; a feed URL with a status
canonical still yields the handle from the candidate that is a post.

`twitter.js:61` still derives the handle from the first segment. The browser extension is
always handed a post link by its right-click context, so the feed case never reaches it
there, and tier 3 is outside this pass; the mirror now differs on a case the JS cannot
produce, and the comment at the Swift site says so.

Also pinned: the `largestMedia` tie rule — all-zero areas yield the first image, not the
last, and a strictly larger later image still wins; `platform(forURLString:)` over
userinfo (`https://x.com@evil.com/` is `evil.com`; `user:pw@x.com` is still x.com), a
lookalike suffix (`x.co`, `x.comm`, `pinterest.com.au`, `sub.x.com.evil.net`), a
percent-encoded dot, and IDN hosts. One IDN case is pinned in the affirmative: Foundation
IDNA-maps fullwidth `ｘ.com` to `x.com` before the host is read, which is what every
browser does with it, so it IS x.com; a Cyrillic lookalike stays punycode and stays
`.web`. And the 280-character title truncation with a title of flags — two scalars per
grapheme — exactly at and one over the limit, asserting the cut never lands inside one.

## The fixtures

`FixtureImages` moved from `AtelierIngestionTests/TestSupport` into
`AtelierCaptureTestSupport` and went public — JPEG, HEIC, an EXIF rotation, a truncated
JPEG, the two-tone and transparent builders. Twenty Ingestion test files use it, so the
old path holds a one-line `typealias` rather than twenty new imports, for the reason the
package proper gives for `ContentHasher`. `CaptureFixtures.png()` is now
`FixtureImages.solidColorImage` under the name sixty-seven call sites use. The verbatim
JPEG copy in `InboxArchiveTests` is gone; the Mac's copy in `InboxArchiveImportTests` is
P4's.

`InboxFixtures.temporaryLibraryRoot(suite:)` replaces the seven hand-rolled temp-root
makers, `makeLayout(suite:)` wraps it for the two suites that want a layout, and
`retain(_:in:movingPayload:)` executes the drain's plan, as above.
`CaptureRequest.sampleContent` gained `originalURL:` and `title:` parameters and
`sampleLink(_:)` replaces the hand-built link request in the archive rig.

`Gate` replaces the `actor` in `InboxDrainTests` and the `@MainActor` class in
`InboxDrainPolicyTests` (the Mac's third shape is P4's). It is a `Mutex`-guarded class
rather than an actor so that `open()` is synchronous: the policy suite reads a trace
immediately after opening a gate, and an actor would have put a suspension point there
and moved every such assertion to after whatever the runtime scheduled first. The
check-and-enqueue in `wait()` is one critical section, so an `open()` that lands between
them cannot strand a waiter, and continuations are resumed outside the lock.

## Manifests, and one claim in the plan that was not so

`AtelierCapture/Package.swift` said the extension "must not link GRDB" and that the
package touches "no filesystem"; 395 corrected the first and `InboxWriter` has contradicted
the second since S2. The header now says what is true: GRDB is linked through AtelierCore
and never opened, the invariant is a behaviour measured against the ceiling, and the
inbox half touches the one directory it is handed.

`AtelierBrowse/Package.swift` depended on `AtelierCapture` "for the library root and the
media paths", which moved to `AtelierLibraryPaths` in 448. The library target drops it;
`BrowseLibrary.swift` had the one stale import. The plan said to keep it on the **test**
target "which uses `InboxWriter`" — it does not: no file under `AtelierBrowse/Tests` names
an `AtelierCapture` symbol, and the two `import AtelierCapture` lines there were as stale
as the source one. The test target now links `AtelierCaptureTestSupport` (for
`InboxFixtures` and `Gate`) and nothing else from that package. `AtelierArchive`'s test
target gains the same product; its manifest header and `LibraryArchiveWriter`'s doc said
`AtelierCapture.LibraryMediaPaths`, and the writer's `import AtelierCapture` was unused.
Both corrected, the import removed.

Two pins. `InboxRecord` decodes with unknown top-level keys present — a keyed decoder
ignores what it was not asked for, and that is today's tolerance, without a
format-version field yet. And a phone-written archive whose `schemaVersion` is newer than
the reader's is refused whole with `.schemaTooNew`, before a record is read.
`LibraryArchiveReaderRefusalTests` already pinned that rule for a Mac-written manifest —
the plan's "also found" list counted it as unpinned — so what the new case adds is that
`InboxArchive.write` puts the phone's version where the rule reads it.

## Files changed

- `AtelierCapture/Sources/AtelierCapture/InboxLayout.swift` — the three payload mirrors,
  `FileMove` and `retentionMoves(for:)`, `replacingMove`, `removeIfPresent`,
  `LazyDirectory`; the header's "creates nothing" paragraph corrected.
- `AtelierCapture/Sources/AtelierCapture/InboxRetirement.swift` — over the primitives;
  its private `move` / `remove` gone; the "phone never drains" paragraphs corrected.
- `AtelierCapture/Sources/AtelierCapture/InboxWriter.swift` — `payloadEmpty`, the floor.
- `AtelierCapture/Sources/AtelierCapture/SSRFGuard.swift` — moved from
  `AtelierIngestion/Sources/AtelierIngestion/Input/`, header rewritten for its new home.
- `AtelierCapture/Sources/AtelierCapture/ShareCapture.swift`,
  `PageHarvest.swift` — their trim-or-nil copies replaced by `TextRules.nonBlank`;
  `PageHarvest` now imports `AtelierCore`.
- `AtelierCapture/Sources/AtelierCapture/PageExtractor.swift` — the status-page handle
  rule; `normalized(_:)` over `TextRules`.
- `AtelierCapture/Sources/AtelierCaptureTestSupport/FixtureImages.swift` — moved from
  `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/`, public.
- `AtelierCapture/Sources/AtelierCaptureTestSupport/InboxFixtures.swift`, `Gate.swift` —
  new.
- `AtelierCapture/Sources/AtelierCaptureTestSupport/CaptureFixtures.swift` — `png()`
  delegates; `sampleContent` gains `originalURL:` / `title:`; `sampleLink(_:)`.
- `AtelierCapture/Package.swift` — header corrected (GRDB, filesystem).
- `AtelierCapture/Tests/AtelierCaptureTests/InboxLayoutTests.swift` — 11 new: the three
  mirrors, the plan (own sidecar, media-less, foreign name), the primitives; the fixture
  maker and `retain` over `InboxFixtures`.
- `AtelierCapture/Tests/AtelierCaptureTests/InboxWriterTests.swift` — 5 new: empty
  `Data`, empty file, one byte, absent-is-not-empty, unknown keys; `shape` / `underlying`
  carry the new case; the root maker over `InboxFixtures`.
- `AtelierCapture/Tests/AtelierCaptureTests/PageExtractorTests.swift` — 5 new: the
  non-status pages (7 arguments), `/i/status/`, the canonical fallback, the tie rule, the
  grapheme boundary.
- `AtelierCapture/Tests/AtelierCaptureTests/ShareCaptureTests.swift` — 9 more arguments
  to the `.web` case and 2 new tests (userinfo before a mapped host, IDNA mapping); the
  round-trip root over `InboxFixtures`.
- `AtelierCapture/Tests/AtelierCaptureTests/SSRFGuardTests.swift` — moved, 10 tests, one
  import changed.
- `AtelierCapture/Tests/AtelierCaptureTests/InboxRetirementTests.swift` — the layout
  maker over `InboxFixtures`.
- `AtelierCore/Sources/AtelierCore/Domain/TextRules.swift` — new.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — `open(libraryRoot:)`,
  `databaseURL(in:)`.
- `AtelierCore/Sources/AtelierCore/Services/SearchRules.swift` — `normalizeText` delegates.
- `AtelierCore/Tests/AtelierCoreTests/TextRulesTests.swift`, `ServicesOpenTests.swift` —
  new, 2 and 3 tests.
- `AtelierLibraryPaths/Sources/AtelierLibraryPaths/LibraryLocation.swift` — the bundle
  parameter on `appGroupIdentifier` and `defaultRoot`; `rawValue:` loses its default; the
  header says which package this is; `overrideValue` says why it stays inline.
- `AtelierLibraryPaths/Tests/AtelierLibraryPathsTests/LibraryLocationTests.swift` — 5
  new: present, absent, blank, the `.main` default, macOS ignoring the bundle.
- `AtelierBrowse/Package.swift` — `AtelierCapture` dropped from both targets;
  `AtelierCaptureTestSupport` on the test target; header corrected.
- `AtelierBrowse/Sources/AtelierBrowse/BrowseLibrary.swift` — `init(root:)` over
  `AppServices.open`; the stale import gone.
- `AtelierBrowse/Sources/AtelierBrowse/BrowseFormat.swift` — `nonBlank` delegates.
- `AtelierBrowse/Tests/AtelierBrowseTests/BrowseLibraryTests.swift`, `BrowseScaleTests.swift`
  — the rig over `InboxFixtures` and `AppServices.open`; stale imports gone.
- `AtelierBrowse/Tests/AtelierBrowseTests/InboxDrainPolicyTests.swift` — its `Gate` gone.
- `AtelierArchive/Package.swift` — `AtelierCaptureTestSupport` on the test target; header
  corrected.
- `AtelierArchive/Sources/AtelierArchive/InboxArchive.swift` — `payloadSite` over
  `ingestedPayloadURL(for:)`; the header's "never drains" corrected.
- `AtelierArchive/Sources/AtelierArchive/LibraryArchiveWriter.swift` — the unused import
  removed.
- `AtelierArchive/Tests/AtelierArchiveTests/InboxArchiveTests.swift` — the JPEG copy,
  the temp base and the hand-rolled `retain` gone; `captureLink` over `sampleLink`; 1
  new (the newer schema).
- `AtelierIngestion/Sources/AtelierIngestion/Input/InboxDrain.swift` — `Pass(layout:)`
  over two `LazyDirectory`s; `retain` executes the plan; `quarantine` / `discard` over the
  primitives; its private `move` gone; the sidecar comment corrected.
- `AtelierIngestion/Sources/AtelierIngestion/Input/SSRFGuard.swift` — now the two
  typealiases.
- `AtelierIngestion/Sources/AtelierIngestion/Input/PageResolver.swift`,
  `RemoteImageFetcher.swift` — `import AtelierCapture`, for the default argument.
- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputFactories.swift`,
  `Pipeline/IngestInput.swift` — the comments corrected.
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestPipeline.swift` —
  `maximumPixelArea`, `checkPixelArea(of:against:)`; the read comment says it reads whole.
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestError.swift` —
  `pixelAreaExceeded(pixels:limit:)`.
- `AtelierIngestion/Tests/AtelierIngestionTests/IngestPipelineTests.swift` — 6 new: at
  the cap, one over, nil, the card-image path, EXIF invariance, overflow.
- `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/FixtureImages.swift` — now the
  typealias.
- `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/TempLibrary.swift` —
  `AppServices.open`.
- `AtelierIngestion/Tests/AtelierIngestionTests/InboxDrainTests.swift` — its `Gate` gone;
  `Pass(layout:)`.

Nothing under `AtelierRefs/` changed. `project.pbxproj` is untouched.

## Verification

`swift test --parallel`, before → after:

| package | before | after |
|---|---:|---:|
| AtelierCore | 771 | **776** |
| AtelierCapture | 133 | **166** |
| AtelierLibraryPaths | 25 | **30** |
| AtelierBrowse | 82 | **82** |
| AtelierArchive | 65 | **66** |
| AtelierIngestion | 483 | **479** |

All passing. Ingestion's count went down by four because ten SSRF tests left for
AtelierCapture and six gate tests arrived; nothing was dropped.

`swift build --triple arm64-apple-ios26.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"`
in AtelierCapture, AtelierBrowse, AtelierArchive, AtelierLibraryPaths, AtelierIngestion →
**Build complete**, all five (the `ios-packages` CI row; `AtelierCaptureTestSupport`
builds for iOS too, `Synchronization` and all).

`xcodebuild build -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'
CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**.

`xcodebuild build-for-testing -scheme AtelierRefsMobile -destination 'platform=iOS
Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**, with no signing
needed. This is the run that compiles `AtelierRefsMobileUITests`, which links
`AtelierLibraryPaths` and `AtelierCapture` — so the bundle parameter and the moved guard
are proven against the one target that would have caught a source break in either.

`xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'
-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`.

**One flake, named because it looked like a failure.** That Mac run was made four times.
Three passed. The one that did not reported `** TEST FAILED **` (exit 65) while two
`swift build` invocations were running concurrently in `AtelierCapture` and
`AtelierIngestion`, which hold those packages' `.build` locks that `xcodebuild` resolves
the same local packages through. Every isolated run is green and nothing in this phase
touches a file in an app target. Recorded rather than dropped, because the next person to
run those two things at once will see it too.

`swift test --parallel` in `AtelierServer` → **62 passed**, unchanged: it links
`AtelierCaptureTestSupport` and was the one other consumer of the fixtures.
`swift build --build-tests` in `AtelierExport` and `CanvasRenderer` → **Build complete**.

`AtelierTokens` was not run: no file in this phase is on its side of the graph.

## What is still NOT covered, stated rather than implied

**The phone has no pixel cap yet.** The gate is a pipeline parameter with a test on both
sides of it, and every caller in the program still passes nil. `MobileIngest.makeDrain`
states the number in P2, and until then a hostile PNG on a phone decodes exactly as it did.

**The extension's fetch has no wall yet.** `SSRFGuard` is where the extension can link it;
the extension does not, until P5. Moving it changed nothing about what either fetcher
does today.

**The three app-side spellings of `library.sqlite` are still there.** `LibraryStore` and
`FixtureLibrary` compose the path by hand; P3 moves them to `AppServices.open`. The
`LibraryStorageScan` in AtelierIngestion also defaults its file name to a string literal
rather than `AtelierCore.databaseFileName`; not touched.

**`BrowseFormat.nonBlank` is a forwarder, not gone.** The app calls it by that name in
`GridTile` and `ItemDetailScreen`; P3 repoints them and the forwarder can go.

**`twitter.js` still derives a handle from any first segment.** The Swift and JS
extractors now answer differently for `x.com/home`, which the JS is never asked; the
`host-table.js` drift gate covers hosts, not this rule, and tier 3 is outside the pass.

**The Mac's copies are P4's.** The JPEG builder in `InboxArchiveImportTests` and the
`Gate` in `InboxDrainSchedulerTests` are the third of each; `AtelierRefsTests` does not
link `AtelierCaptureTestSupport` yet.

**`InboxRetirement.moveToSent` still spells its own two moves.** The retention plan
covers `ingested/`; the retire-to-`sent/` order (payload first, then record) has one
executor and no fixture, so it was left where it is, over the shared primitives.

**Unknown record keys are tolerated; unknown request keys inside `request` are
`CaptureRequest`'s business** and were not pinned here. The archive pin covers a newer
schema, not a newer `manifestVersion` from the phone — the reader's own suite has that
one.

**Nothing has run on a device**, and the writer's floor was exercised with a sparse file
and an empty `Data`, not with a provider that hands over an empty representation.

## Migration notes

**API additions**, all source-compatible:

- `InboxLayout.failedPayloadURL(for:)`, `sentPayloadURL(for:)`, `ingestedPayloadURL(for:)`;
  `InboxLayout.FileMove` and `retentionMoves(for:)`; `InboxLayout.replacingMove(_:to:)`,
  `removeIfPresent(_:)`, `InboxLayout.LazyDirectory`.
- `TextRules.nonBlank(_:)` in AtelierCore. `BrowseFormat.nonBlank` still exists and
  delegates.
- `AppServices.open(libraryRoot:)`, `AppServices.databaseURL(in:)`.
- `InboxWriteError.payloadEmpty`. Any exhaustive `switch` over `InboxWriteError` outside
  the packages needs the case; none exists in the tree today.
- `IngestPipeline.init(store:services:tiers:maximumPixelArea:timing:)` — the new parameter
  defaults to nil; every existing call compiles unchanged. `IngestError.pixelAreaExceeded
  (pixels:limit:)` — likewise, no exhaustive switch exists outside the enum's own mapping.
- `LibraryLocation.appGroupIdentifier(bundle:)` and `defaultRoot(bundle:)`, both
  defaulted to `.main`. `appGroupIdentifier(rawValue:)` **no longer has a default**; a
  call spelled `appGroupIdentifier()` still compiles and now resolves to the bundle
  overload, with the same result.
- `SSRFGuard` / `SSRFError` are `AtelierCapture` types; `AtelierIngestion.SSRFGuard` is a
  typealias. A file that spells `SSRFGuard()` as a **default argument** must import
  `AtelierCapture` by name.
- `AtelierCaptureTestSupport`: `FixtureImages` (public, formerly Ingestion-internal),
  `InboxFixtures`, `Gate`, `CaptureRequest.sampleLink(_:)`, and `originalURL:` / `title:`
  on `sampleContent`.

**Internal**: `InboxDrain.Pass()` is `Pass(layout:)`. `PageExtractor.twitter` no longer
records a handle for a non-status X page — a capture of `x.com/home` made after this
carries `authorHandle: nil` where before it carried `@home`; nothing rewrites records
already in an inbox.

**Manifests**: `AtelierBrowse`'s library product no longer links `AtelierCapture`. Any
future file under `AtelierBrowse/Sources` that wants a Capture symbol has to add the
dependency back, on purpose. No file format, no schema, no on-disk layout and no
user-facing string changed.
