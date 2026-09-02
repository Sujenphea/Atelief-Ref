# 098 — iOS companion: the completion pass (plan)

> What is left between the companion as it stands on `feat/ios-ingest` (2026-09-02,
> HEAD `bb841bd`) and a v1 that is *finished* rather than *landed*. Planned against the
> code, not the earlier docs: every claim below was read at the file cited today.
>
> **Amended 2026-09-02, same day.** The first draft of this doc was written unattended and
> took its own decisions. It was then re-reviewed with the user, section by section
> (architecture, code quality, tests, performance), against four independent read-only
> reviews of the same tree. Every decision below was taken by the user in that session.
> Where the unattended draft had decided differently, the earlier decision is recorded
> beside the new one so the reversal is visible — findings 2 and 10, and the unit-test
> target. The scope is the same: the companion app only. Tier 3 stays out.
>
> **State at the time of writing.** Every slice [092](092-ios-companion-plan.md) named is
> built and has run — S0–S4a on the host, S4b–S6 on a simulator and, for the share sheet
> and AirDrop, on a device. [452](../.change-log/452-the-factories-were-never-the-appkit-part.md)–[455](../.change-log/455-what-the-move-found.md)
> then gave the phone its own drain, so a share appears in the phone's grid without a
> Mac. The capture-to-library loop is closed on both ends.
>
> What is NOT here: tier 3. [096](096-tier3-plan.md) is gated on T0, and T0 is a device
> session ([097](097-tier3-t0-protocol.md)) — thirty popup openings per platform on a
> phone in someone's hand. Nothing an agent does today moves it, and 096 says in its own
> words not to start T1 before it is answered. This plan does not.

## What "complete" means for this pass

The companion has a habit, recorded in every changelog since 454, of closing with a
paragraph titled *what is still NOT covered*. This pass is that paragraph, worked through:
the seams the last six changelogs named and left, the defects four reviews found that no
changelog had named, plus the things a person installing the app notices before they
read any of them — its name, its icon, the flash before its first frame.

Six phases. Each is one agent, one changelog, one or more commits, run in order because
every phase touches files the next one reads. None of them needs a device; the things
that do are listed at the end, unclaimed.

Decisions the user took that shape the whole pass, recorded once here:

- **Scope: the companion app only.** Share extension, inbox, drain, browse, export, plus
  their missing tests, DRY, edge cases, undesigned screens and doc drift.
- **Surfaces in scope:** empty and error states; app icon and launch screen; the full
  item-detail layout. **Deferred:** phone search, iPad.
- **Browse stays read-only.** 093 open question 1 closes as *no*: the Mac stays the
  curation surface, and the archive import gains no membership-change conflict class.
- **The analysis stack stays off the phone**, per 091's recorded lean.
- **No phone-hosted unit-test target.** Not for 454's cost argument alone, but because
  once the export controller, the store, the failure vocabulary and the decode cache
  live in `AtelierBrowse`, what would remain in the bundle is a `ScenePhase` mapping and
  two constants. A pbxproj target and a simulator unit lane for that is the wrong trade.
  The simulator lane for the UI tests still lands (finding 10).

## The review, and what was decided

Fifteen issues under four headings, numbered as they were put to the user; the
unattended draft's findings are folded in where they land. Each carries its options,
the recommendation, the decision, and the phase that carries it. Where the honest
recommendation was *do nothing*, it says so and stops.

### Architecture

**1. Phone failure fates: a crash mid-ingest retries forever, and a quarantine silently
drops the capture from the export.** An attempt is stamped only after the coordinator
reports `.failed` (`InboxDrain.swift:602-620`); nothing is written before a record runs.
Jetsam mid-ingest leaves the record pending at `attempts: 0`, so it re-runs at every
launch and every foreground — the ordinary failure on a phone, with no UI to break it.
When attempts do reach three, or the re-stamp throws on a full disk, the record moves to
`inbox/failed/`, which `InboxArchive.pendingRecords(in:)` does not read
(`InboxArchive.swift:141-148`, pinned by `InboxArchiveTests.swift:367`). A capture the
phone cannot ingest is lost to the Mac, the one consumer that matters.

- A — write-ahead attempt stamp (restored on `.cancelled`, so backgrounding never spends
  one) **and** a retention-aware terminal fate: under `.retainForExport` an exhausted or
  un-stampable record stays in the pending set with its count, the drain skips it
  (`skippedExhausted`), the export still sends it; only malformed records go to
  `failed/`. Effort M.
- B — the stamp only. C — the export reads `failed/` too. D — nothing.

**Decision: A. Phase 2.**

**2. The tier-2 media fetch has no SSRF wall, and its size gate runs after the body
lands.** `ShareCapture.mediaCandidates` filters on scheme only (`ShareCapture.swift:391-395`);
`fetchMedia` (`ShareViewController.swift:655-684`) follows redirects unchecked and reads
`expectedContentLength` only after `download(for:)` has returned — the comment above it
says the opposite. The Mac walls the identical fetch with `SSRFGuard`
(`AtelierIngestion/Input/SSRFGuard.swift`, Foundation + Network, injectable DNS, tested),
which the extension cannot link.

- A — move `SSRFGuard` and its tests to `AtelierCapture`, typealias it from
  `AtelierIngestion` the way `ContentHasher` is; validate each candidate, re-validate each
  redirect hop through a task delegate, cancel on the response when the expected length
  exceeds the cap; fix the comment. Effort M.
- B — host-string refusal only. C — fix the comment only.

**Decision: A. Phases 1 (the move) and 5 (the fetch).**

**3. Ingest reads every payload whole, has no pixel-area gate, and four comments say the
bytes stay on disk.** `IngestPipeline.storeBytesBlobFirst` does `Data(contentsOf:)`,
hashes in memory and `storeBlob(Data)` (`IngestPipeline.swift:147-174`) although
`ContentHasher.hash(contentsOf:)`, `MediaStore.storeBlobFile(copyingFrom:)` and
`ImageDecoding.thumbnailCGImage(from: URL)` exist. `Validation.swift:128-130` checks only
that dimensions are positive, so a very large PNG decodes unbounded — with finding 1, a
deterministic crash loop from one hostile page.

- A — a streaming `.fileURL` path plus the gate plus the comments. Touches the Mac's hot
  path for every ingest.
- B — the pixel-area gate (from header metadata, a pipeline parameter beside `tiers`,
  nil on the Mac), the four comment fixes, and `IngestTiming` wired to the phone's log
  behind a launch flag so drain width 2 gets a device number before anyone rewrites the
  storage stage. Effort S ×3.
- C — nothing.

**Decision: B.** Finding 1 closes the loop, the gate closes the decode bomb, and a
rewrite of the storage stage waits for the measurement. **Phase 1** (gate, comments),
**Phase 2** (timing).

**4. Storage lifecycle on the phone: three copies per capture, export folders never
cleaned, derived files backed up.** After a drain with retention a capture is the
ingested sidecar, a full blob copy, and tiers. `CaptureExport.write` removes only a
same-named folder (`CaptureExport.swift:208-215`), so every send at a different minute
leaves its predecessor in `Caches/Exports/`, free until "Clear" deletes the ingested
payloads and each old folder becomes the sole owner of those bytes.
`MobileIngest.makeDrain` never calls `excludeDerivedFromBackup()` (the Mac does,
`IngestionModel.swift:779`).

- A — `InboxArchive.writeExport(records:layout:under:appVersion:now:)` in
  `AtelierArchive` clears every sibling export folder, creates the timestamped one,
  writes, returns the folder and ids — tested with stale siblings; the phone drain
  excludes `thumbnails/`, `cache/` and the export directory from backup. Safe because an
  export runs under `InboxExclusion` with the send control disabled on `.working` and
  the share sheet modal.
- B — A plus clone-based blobs (only with 3A). C — rely on the purge.

**Decision: A. Phase 2.**

### Code quality

**5. One drain policy, two schedulers.** The Mac's `AtelierRefs/InboxDrainScheduler.swift:119-130`
re-implements the guard-and-claim that `InboxDrainPolicy.drain` implements at
`InboxDrainPolicy.swift:245-280`; `report(_:)` is byte-identical between
`InboxDrainScheduler.swift:143-160` (Mac) and `AtelierRefsMobile/InboxDrainScheduler.swift:112-129`
apart from the logger. 455 named it and left it.

- A — the Mac links `AtelierBrowse` and adopts `InboxDrainPolicy<DrainSummary>` behind a
  `NotificationCenter` adapter; the report wording becomes a pure
  `DrainSummary.reportLines` in `AtelierIngestion`, tested, and both apps only route
  lines to their logger. Effort M.
- B — share only `reportLines` and the duplicated `move`. C — nothing.

**Decision: A**, with B's `reportLines` landing first inside the same phase so it stands
on its own if the adapter has to stop. **Phase 4.** (The unattended draft chose B-then-A
as its last phase; same end state.)

**6. `AtelierBrowse` restates Mac rules, the charter reason has expired, and one rule
has drifted.** The package header says the copies exist because S5 could not edit the
Mac app; later slices did (Tokens, Archive). `BrowseFormat.savedDate/platform` equal
`DetailFormat` (`ItemDetailView.swift:2455-2477`); `BrowseFormat.author` trims
`.whitespacesAndNewlines` while `SourceSection.author` (`:1763-1773`) trims
`.whitespaces` — a trailing newline renders differently on the two platforms;
`MasonryColumns` restates `MasonryLayout`'s clamps and column width;
`BrowseCollectionTree` restates `CollectionTargets`' ordering and tree with the same
cycle guard. Five "cite the Mac line" comments are already stale.

- A — the Mac links `AtelierBrowse` (the link 5A introduces) and deletes its copies; the
  Mac masonry solver reads the package's constants; one trim rule, the stricter.
- B — move the pure bits into `AtelierCore`. C — fix citations and the drift by hand.

**Decision: A. Phase 4.**

**7. `ShareViewController` is 848 lines doing five jobs, with seven handling gaps.**
Hosting, orchestration, provider harvesting (`:258-330`, `:686-847`), page snapshot
loading (`:377-482`, `:512-555`), footprint instrumentation (`:484-510`), media fetch
(`:557-684`). The gaps: `loadData` drops its error unlogged (`:821-829`); both image
routes failing beside a page URL silently saves a link and reports success
(`:288-303`); the `expectedContentLength` comment is false (`:648-650`); a temp file
leaks when `adopt` throws after a fetch (`:679`); page text, titles and chosen media
URLs are logged `privacy: .public` (`:141-145`, `:352-375`); `footprint()` runs in
Release; two bundle ids are hand-spelled (`:91`, `MobileIngest.swift:37`). And
`payloadTooLarge` shows "Try sharing again", which cannot work (`ShareCard.swift:193-198`).

- A — split into `PageSnapshotLoader`, `ProviderPayloads`, `MediaFetcher` (all already
  `static`), fix all seven, a typed `.tooLarge` card, and the cap check and response
  acceptance as pure predicates in `ShareCapture` so they are host-testable. Effort M.
- B — the fixes only. C — nothing.

**Decision: A. Phase 5.**

**8. The send count can be wrong forever, nothing cleans `ingested/`, and an empty
payload is accepted.** `CaptureExport.refresh()` counts `.json` files
(`CaptureExport.swift:102-106`); `InboxArchive.pendingRecords` `try?`-drops what will
not decode (`:145`) and `write` skips a record whose payload is missing without naming
it; `retire()` takes only `exported`; the drain quarantines unparseable records at the
top level but never looks in `ingested/`. One corrupt ingested record is "Send 1"
forever, and alone it is an export that fails forever. `InboxWriter.write` refuses only
`size > maximumPayloadBytes` (`InboxWriter.swift:263-270`): a 0-byte payload writes, fails
ingest three times, and is unprobeable at export — both wedges at once.

- A — count decodable records and surface `unreadable` in the archive summary so the
  button and the manifest agree; the retaining drain quarantines an ingested record that
  will not decode or whose payload is absent from both sites; the writer refuses zero
  bytes with a typed error. Effort S ×3.
- B — the count only. C — nothing.

**Decision: A. Phase 1** (the writer), **Phase 2** (the rest).

Batched with no separate decision: the duplicated `move` and lazy-mkdir helpers and the
hand-composed payload mirrors fold into `InboxLayout` (which already says "composition
lives here or it drifts" and then provides only the record mirrors); the four copies of
trim-or-nil become one; the three hand-built database opens become
`AppServices.open(libraryRoot:)`; the phone's thumbnail decode and cost delegate to
`ImageDecoding`; `TileBodyLog` goes behind `#if DEBUG`; dead `BrowseLibrary.init(root:)`
and the unused theme forwarders go; `cardChrome()` / `fieldChrome()` land in
`AtelierTokens` beside the existing `elevation(_:)`; string keys become named constants.

### Tests

**9. Every line of the phone app target's logic is untested, and CI runs no iOS test.**
Five targets, none hosting a unit test in the phone app. `CaptureExport` and
`LibraryStore` import no UIKit, yet the export phase machine, the count semantics, the
bootstrap failure mapping, the feed generation guard and the scene-phase mapping have no
test; `MobileIngest`'s width and tiers are restated in `NarrowedThumbnailTiersTests.swift:35`
("this is a copy"); `ThumbnailCache`'s byte bound and bucket rounding are unobserved.
`ci.yml` builds the two iOS targets and stops.

- A (as first put) — move the Foundation-only types into `AtelierBrowse`, then a
  phone-hosted unit bundle for the residue.
- B — the package move only. C — the bundle only. D — nothing.

**Decision: B, revised from A once finding 15 moved the decode cache into the package**
(see the scope note above). `CaptureExport` becomes an export controller in
`AtelierBrowse` with an injectable root and injected write/retire; `LibraryStore` and
`CollectionFeed` move with an injectable root; `BrowseFailure.message(for:)` carries the
sentences (the unattended draft's finding 8). **Phase 3.**

**10. The UI tests never run anywhere, and the one that matters cannot run.**
`Tier2ShareUITests.swift:174` resolves the App Group through `Bundle.main`, which in a
UI test is the runner (455). It also reads only `pendingRecordURLs()` (`:178`); since 454
the app drains at launch, so the record it looks for has moved to `inbox/ingested/` by
the time it looks — it would fail by construction once it could run (the unattended
draft's finding 3). The switcher and export suites are runnable and in no CI job; the
scheme's test action would include the broken tier-2 test in a naive run; the export
test never drives Clear or Keep. CI never compiles the UI bundle (draft finding 4).

- A (as first put) — resolve the group in the test from its own bundle via the public
  seams; env-gate tier 2; a simulator CI job for the two runnable suites; Clear and Keep
  cases.
- B — a defaulted `bundle:` parameter on `LibraryLocation.appGroupIdentifier` /
  `defaultRoot`, host-tested over a bundle written to a temp directory (present, absent,
  blank); the test passes `Bundle(for: Self.self)`.

**Decision: B for the seam, revised from A** — A copied three lines of the seam's own
resolution into the test and left the default silently wrong for the next runner — plus
everything else in A: pending ∪ ingested, the env gate with `XCTSkip`, `build-for-testing`
on the mobile scheme, a simulator job running `SwitcherUITests` and `ExportUITests`, and
the Clear / Keep cases. **Phase 1** (the seam), **Phase 6** (the rest).

**11. The export-versus-drain exclusion is proven only against stand-in bodies.**
`InboxDrainPolicyTests` uses `Outcome == Int` and an export body that appends a string.
Nothing runs the policy over a real `.retainForExport` drain moving records while
`InboxArchive.write` resolves payloads. The packages cannot see each other by design; the
only host that links both is the Mac test bundle.

- A — `AtelierBrowse` as a product dependency of `AtelierRefsTests` only, and one
  integration: policy over a real drain at width 2, a 30-record inbox, an export fired
  mid-pass; assert zero skips, every manifest file present, holders back to zero,
  pending + ingested == 30. Plus a package-hosted export-controller test against a real
  archive with a simulated drain once the controller moves.
- B — the package test only. C — nothing.

**Decision: A. Phase 3** (package test), **Phase 4** (integration).

**12. Fixtures are copy-pasted across packages, phone-native formats never cross the
inbox, extractor negatives are thin, and one absence hides a bug.** The JPEG builder is
identical in `InboxArchiveTests.swift:507-522` and `InboxArchiveImportTests.swift:183-198`;
a richer builder with HEIC and orientation is internal to
`AtelierIngestionTests/TestSupport/FixtureImages.swift`. A hand-rolled copy of the
drain's retention move order lives in `InboxLayoutTests.swift:44-58` and
`InboxArchiveTests.swift:473-488` — a change to the drain leaves both green. Seven
temp-root makers, three `Gate`s in three shapes, two link-request builders duplicating
`CaptureRequest.sampleContent`. No HEIC, GIF, WebP or EXIF-rotated payload is ever
drained, exported or imported. `PageExtractor.twitter` (`:86-91`) derives a handle from
the first path segment of any URL, so sharing `x.com/home` records `authorHandle: "@home"`;
no test feeds it a non-status page.

- A — the JPEG/HEIC/oriented builders, an `InboxFixtures` namespace (temp inbox, retain)
  and one `Gate` move into `AtelierCaptureTestSupport`; the archive and Mac suites link
  it; the copies go. Drain, archive and import parameterised over PNG, JPEG, HEIC, an
  EXIF-rotated image and a GIF with an explicit fate (HEIC skips loudly where the encoder
  is absent). The extractor negatives, and non-status X pages yield no handle.
- B — consolidation only. C — formats and negatives only. D — nothing.

**Decision: A. Phase 1** (consolidation, extractor), **Phase 2** (formats), **Phase 4**
(the Mac suite's copy).

Batched with no separate decision: a failure-path sweep for the branches no test reaches
(archive copy failure, manifest write failure, inline-image records through drain and
archive, re-stamp failure, quarantine fallback, `InboxRetirement.Summary.failed > 0`,
`fileExtension(forMIMEType:)`, writer `rewrite` failures); `onlyOneCaseDrains`'s 0.3 s
wait replaced by the synchronous `isDraining` check it already proves; the two
`LibraryLocationTests` default-root cases pointed at a temp path instead of the real
Application Support folder; today's tolerance of unknown record keys and a newer archive
schema version pinned, without adding a format-version field yet.

### Performance

**13. Opening one item reads the whole collection.** `ItemScreen` does
`store.items(in:).first { … }` (`ContentView.swift:325-328`) — the full P14 join measured
at 0.293 s for 5,000 rows (450), paid per tap. And `CollectionFeed.load` reads the
collection while `BrowseLibrary.items(in:)` reads it again for `sortMode`
(`BrowseLibrary.swift:88`) — the draft's finding 6.

- A — `AppServices.collectionItem(id:in:includeArchived:)` in `AtelierCore` (present,
  absent, archived-hidden, wrong collection); `BrowseLibrary.feed(for:)` returning the
  collection, items and subcollections from one collection read, and `item(_:in:)`; a
  `BrowseScaleTests` ceiling that one item resolves under 50 ms at 5,000, and a
  newest-order variant of the existing scale test.
- B — a lookup closure from the feed. C — nothing.

**Decision: A. Phase 3.**

**14. The grid re-partitions on every body evaluation, and two unconditional stores
trigger extra evaluations.** `MasonryGridView.body` recomputes
`MasonryColumns.distribute` inline (`:43-45`); `refreshCollections` / `refreshCovers`
assign unconditionally (`LibraryStore.swift:133, 147`). Low single-digit ms at 20k,
reasoned, off the scroll path.

- A — `!=` guards on the two stores, and a distribution timing test over 20,000
  elements with a generous ceiling. B — memoise in view state (rejected: O(n) key).
  C — nothing.

**Decision: A. Phase 3.**

**15. Thumbnail decodes are neither coalesced nor cancelled.** `ThumbnailCache.image(at:)`
(`ThumbnailImage.swift:75-84`) spawns a detached decode per miss; two views asking for one
key decode twice; a tile scrolled off cancels the SwiftUI task, not the decode. The byte
bound is honoured (real bitmap cost on insert, 96 MB, 240 entries — 440).

- A (as first put) — a cancellation check and a decode counter behind the launch flag;
  measure a fling before building more.
- B — a generic `DecodeCache<Value: AnyObject>` in `AtelierBrowse`: keyed, byte- and
  count-bounded with the budgets and their arguments carried over, coalescing by key,
  cancellation observed before a decode starts, decode injected; tested with a fake
  decoder that counts calls and parks on a gate. `ThumbnailCache` becomes the app's
  instantiation over `ImageDecoding`; `maxPixel` rounding moves and is tested.
- C — propagate cancellation into the detached task.

**Decision: B, revised from A** — the unattended draft's finding 10. Its tests are the
ones a hosted bundle would have provided, under `swift test`, and it is what lets the
hosted bundle go. The decode counter behind the flag still lands. **Phase 3.**

Recommended *do nothing*, with the number: text-card tiles decode a small JSON per
render (bounded by visible tiles, ≤2 ms per evaluation); the inbox directory count on
main per activation (≤400 dirents at 200 records, low ms); the library open on main at
launch (an APFS clone and a no-op migration, milliseconds). Drain width 2 and its
head-of-line chunking stay unmeasured until the timing from finding 3 runs on a device.

### Also found, decided without a question

- **Tier-1 link shares never get og-tags, on either platform**, though `ShareCapture.swift:58-60`
  and 092 · S4b say the drain enriches: `InboxDrain.makeInput` routes a `link` to
  `remoteContent` (`InboxDrain.swift:560-563`) and `PageResolver` is only called from the
  Mac's paste path. The phone tile shows the raw URL. **Decision:** `BrowseFormat.title`
  falls back to the host name for a bare link, no network (Phase 3); the two docs are
  corrected (Phase 6); Mac-side enrichment after import is a follow-up outside this pass.
- **`PagePreprocessor.js` caps `images` at 80 but not `videos` or `metas`, filters `data:`
  only in Swift, and caps no string length** — a page with inline base64 images ships
  megabytes across XPC into a ~120 MB process. Capped in JS with cases in
  `ios-preprocessor.test.js` (Phase 5).
- **Stale manifests:** `AtelierCapture/Package.swift:21-24` still says the extension must
  not link GRDB (395 corrected it); `AtelierBrowse/Package.swift` depends on
  `AtelierCapture` "for the library root and media paths", which moved to
  `AtelierLibraryPaths` in 448 — no source file under `AtelierBrowse/Sources` uses a
  Capture symbol. Headers fixed, the library-target dependency dropped (Phase 1).
- **The app has no name, no icon, a blue accent and a black launch** (the draft's
  finding 5): no `INFOPLIST_KEY_CFBundleDisplayName`, an empty `AppIcon.appiconset`, an
  empty `AccentColor`, and `INFOPLIST_KEY_UILaunchScreen_Generation` on
  `systemBackground`. Display name `AtelierRefs`, the Mac's 1024 as the universal icon,
  `AccentColor = inkPrimary`, a `UILaunchScreen` dictionary on a `LaunchBackground` colour
  set at `canvasOuter`, verified by reading the keys back out of the built product
  (Phase 6).
- **Doc drift:** 092 · "Where this stands" still says the phone has no drain; 013 still
  records the iOS companion as "not selected"; 091 open question 3 (the analysis stack)
  and 093 open question 1 (one write in browse) are closed above. Amended in Phase 6.

---

## P1 — package foundation

Findings 2 (the move), 3 (gate, comments), 8 (the writer), 10 (the seam), 12
(consolidation, the extractor), the stale manifests, and the DRY batch that lives in
packages. No app-target change.

- `InboxLayout`: `failedPayloadURL(for:)`, `sentPayloadURL(for:)`, `ingestedPayloadURL(for:)`,
  a shared replacing move and a lazy-directory helper; `InboxDrain`, `InboxRetirement`
  and `InboxArchive` call them. One trim-or-nil in `AtelierCore`; `AppServices.open(libraryRoot:)`.
- `InboxWriter` refuses an empty payload with a typed error, tested beside the cap
  boundary cases.
- `SSRFGuard` and its tests move to `AtelierCapture`; `AtelierIngestion` typealiases it.
- The pixel-area gate: a pipeline parameter beside `tiers`, read from header metadata
  before any decode, nil on the Mac, tested; the four "bytes never leave disk" comments
  say what happens.
- `LibraryLocation.appGroupIdentifier(bundle:)` / `defaultRoot(bundle:)`, `.main`
  defaults, tests over a bundle written to a temp directory.
- `PageExtractor`: non-status X pages yield no handle; negatives for `/home`,
  `/i/bookmarks`, `/explore`, a profile; the `largestMedia` tie rule; userinfo, IDN and
  lookalike hosts; a grapheme-heavy title at the truncation boundary.
- `AtelierCaptureTestSupport`: JPEG, HEIC and oriented builders (from `FixtureImages`),
  `InboxFixtures`, one `Gate`; `AtelierArchive`'s test target links it; the copies in the
  Capture, Browse and Archive suites go.
- Pins: unknown record keys decode; a newer archive schema version has a stated outcome.
- Manifest headers corrected; `AtelierBrowse`'s library target drops `AtelierCapture`.

**Verify:** `swift test` in `AtelierCore`, `AtelierCapture`, `AtelierLibraryPaths`,
`AtelierBrowse`, `AtelierArchive`, `AtelierIngestion`; both iOS targets build.

## P2 — drain fates and export correctness

Findings 1, 4, 8 (the rest), 3 (timing), 12 (formats), and the test batch.

- The write-ahead stamp, restored on `.cancelled`; the retention-aware terminal fate;
  `DrainSummary.skippedExhausted`; the ingested-site janitor. Tests in `InboxDrainTests`
  ("under .retainForExport an exhausted capture stays exportable", "a crash counts as an
  attempt", "a cancelled record spends nothing") and `InboxArchiveTests` ("a capture the
  phone could not ingest is still sent").
- `InboxArchive.pendingRecords` reports the unreadable count; `Summary.skipped` includes
  it; the phone's count is decodable records.
- `InboxArchive.writeExport(...)`, tested for the stale sibling, the fresh folder, the
  name and the ids; `MobileIngest.makeDrain` excludes derived files and the export
  directory from backup.
- The drain, archive and import tests parameterised over PNG, JPEG, HEIC, EXIF-rotated
  and GIF.
- The failure-path sweep; the two flake fixes.
- `IngestTiming` wired to `MobileLog` behind `-atelier-log-ingest-timing`;
  `FixtureLibrary.pendingCaptures` parameterised so a debug run seeds a backlog.

**Verify:** `AtelierIngestion`, `AtelierArchive`, `AtelierCapture`, `AtelierBrowse`,
`AtelierLibraryPaths` suites; `AtelierRefsTests` on the Mac (`InboxArchiveImportTests` is
the only test that runs both ends of the export); both iOS targets build.

## P3 — the browse seam, and the phone's logic where tests reach it

Findings 9, 11 (package half), 13, 14, 15, the link-title fallback, and the code-quality
batch.

- `AppServices.collectionItem(id:in:includeArchived:)`; `BrowseLibrary.feed(for:)` and
  `item(_:in:)`; the scale ceilings.
- The export controller, `LibraryStore`, `CollectionFeed` and `BrowseFailure` in
  `AtelierBrowse`, roots and I/O injected, tested; the app's files shrink to callers.
- `DecodeCache` in `AtelierBrowse`; `ThumbnailCache` becomes its instantiation over
  `ImageDecoding.decodedThumbnail` / `byteCost`; the decode counter behind
  `-atelier-log-tile-bodies`.
- The `!=` guards and the distribution timing test.
- `BrowseFormat.title` host-name fallback.
- `TileBodyLog` under `#if DEBUG`; dead code and unused forwarders gone; `cardChrome()`
  / `fieldChrome()` in `AtelierTokens`; named constants for the string keys.

**Verify:** `AtelierCore`, `AtelierBrowse`, `AtelierTokens` suites; the iOS app builds;
the UI test bundle still compiles.

## P4 — the Mac adopts the browse package

Findings 5, 6, 11 (the integration), 12 (the Mac suite's copy).

- `DrainSummary.reportLines` in `AtelierIngestion`, tested; both apps log it.
- The Mac app links `AtelierBrowse`; its scheduler becomes a `NotificationCenter` adapter
  over `InboxDrainPolicy`; `InboxDrainSchedulerTests` re-pointed without weakening an
  assertion.
- `DetailFormat`, `SourceSection.author` and the `CollectionTargets` ordering and tree
  go; `MasonryLayout` reads `MasonryColumns`; `.whitespacesAndNewlines` on both.
- `AtelierRefsTests` links `AtelierBrowse` and `AtelierCaptureTestSupport`; the
  integration test; the JPEG builder copy goes.

**Verify:** the full `AtelierRefsTests`; the Mac app builds; `xcodebuild -list` after
every pbxproj write; `AtelierBrowse` and `AtelierIngestion` suites.

## P5 — the share extension

Findings 2 (the fetch), 7, and the preprocessor caps.

- `PageSnapshotLoader`, `ProviderPayloads`, `MediaFetcher`; the seven fixes; the typed
  `.tooLarge` card; `ShareCapture.acceptsFetched(length:status:)` and the cap predicate,
  tested.
- The SSRF-walled fetch: candidates validated, redirects re-validated in a task delegate,
  the download cancelled on an oversized response; the comment corrected.
- `PagePreprocessor.js`: `videos` and `metas` capped, `data:` sources dropped, string
  lengths capped; cases in `extension/test/ios-preprocessor.test.js`.

**Verify:** `AtelierCapture` suite; `node --test` in `extension/`; the share extension and
the app build for the simulator.

## P6 — surfaces, the UI tests in CI, and the docs

Findings 10 (the rest), the app's name and icon, the surfaces in scope, the doc drift.

- Display name, icon, accent, launch colour; read back from the built product.
- Empty and error states per 093 § 7: empty library, empty collection, failed drain,
  failed export, missing App Group.
- The item-detail layout per 093: image, title, author, platform, collection, saved
  date, dimensions, open-source link — over `BrowseFormat`.
- `Tier2ShareUITests` passes its own bundle, reads pending ∪ ingested, is gated on
  `ATELIER_RUN_SAFARI_TESTS` with `XCTSkip`; `ExportUITests` gains send → sent → Clear,
  and Keep.
- `ci.yml`: `build-for-testing` on the mobile scheme; a simulator job running
  `SwitcherUITests` and `ExportUITests`.
- 092 · "Where this stands" amended; 013's "not selected" note amended; 091 · Q3 and
  093 · Q1 closed; `ShareCapture.swift:58-60` and 092 · S4b corrected about links; this
  doc's status closed.

**Verify:** both iOS targets build; `SwitcherUITests` and `ExportUITests` pass on a local
simulator; `xcodebuild -list`; every doc cross-link resolves.

---

## Left to the user, and blocking nothing here

- **T0** ([097](097-tier3-t0-protocol.md)) — the focal-post session. Tier 3 waits on it.
- **`sujenphea.AtelierRefsMobileUITests` as an App ID with App Groups** (446, 097). P6
  makes the test correct; this is what makes it run signed.
- **Tier 2 on an auth-walled page, on hardware** — the one thing tier 2 exists for and
  the one thing a loopback fixture cannot stand in for.
- **`MobileIngest.maxConcurrent`** — a drain of a seeded backlog on a device with
  `-atelier-log-ingest-timing`, width 2 against 4.
- **A fling over the 2,010-item fixture** with the decode counter on, to decide whether
  the `DecodeCache` coalescing is ever hit.
- **The jetsam claim** — a crash mid-ingest on a device, then a launch: the record's
  `attempts` reads 1.
- **093 open question 2** — `successDismissDelay`, set once on a device.
- **App Store presence** — a privacy manifest, version numbers, screenshots. 093 § 7
  excluded it and this pass does too.

## Out of scope, named so it is not mistaken for this

The Mac app's backlog — the ⌘K switcher, the floating palette, a Mac Safari extension,
the competitor importers, the Instagram export backfill, the RedNote sweep, smart
collections, the search and Spaces and detail lists, the color filter's second mode,
multi-library, undo-of-delete, the one code `TODO` in `twitter.js`, and the deferred
capture work — is a different product surface and is not touched by any phase above.
Also out: phone search, iPad, a write action in browse, the analysis stack on the phone,
Mac-side og-tag enrichment of imported links, and a streaming storage stage in the
pipeline (waits on the timing from P2).
