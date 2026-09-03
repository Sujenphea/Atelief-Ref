# 099 — Mac backlog: the completion pass (plan)

> What is between the Mac app as it stands on `feat/ios-ingest` (2026-09-02, HEAD
> `3bf4d7e`) and the backlog closed. Planned against the code, not the earlier docs:
> every claim below was read at the file cited today, across all eleven packages, the
> app target, the extension and the CI configuration.
>
> **How this plan was made.** A four-section review — architecture, code quality,
> tests, performance — with four issues per section, each carrying its options, its
> effort / risk / blast-radius / maintenance, and a recommendation. The user decided
> every one. Those sixteen decisions are constraints on every phase below; no phase
> re-opens them.
>
> **What is NOT here.** Anything blocked on an input only the user can produce:
> the Instagram export-ZIP backfill (needs a fresh `saved_posts.json`), the rednote
> board sweep and video ladder (needs a >30-note pagination fixture), a second
> library, the extension reverse channel, Instagram and Cosmos bulk sweeps, sweeping
> while the app is closed, the GDPR archive path. Visual search (MobileCLIP), score
> fusion, multilingual embeddings and search inside Spaces stay deferred as the user
> listed them; this plan builds only the measurement and the bounded cache the
> visual-search item would stand on (15A). The two text engines stay two —
> [067](067-spaces-text-engine-research.md) measured that and said not to.

## The situation this plan lands in

Three facts shape the sequencing more than any finding did.

1. **A second session is executing [098](098-ios-companion-completion-plan.md) on
   this branch right now.** Four commits landed while this plan was being written
   (`7565d1e`, `3a7da82`, `af79940`, `3bf4d7e`), and the working tree carries an
   uncommitted rename. 098 · P4 — *the Mac adopts the browse package* — moves
   `CollectionTargets`' ordering and tree into `AtelierBrowse`, points `MasonryLayout`
   at `MasonryColumns`, and puts the Mac's `InboxDrainScheduler` over
   `InboxDrainPolicy`. That is exactly two of this review's findings (5A's second
   half, and the masonry constants), so they are **dependencies here, not work**.
   Everything in this plan runs in its own worktree on its own branch, and the one
   phase that overlaps P4's files waits for P4.
2. **CI has not run a step since 2026-08-06.** Every job on every run reports *"The
   job was not started because recent account payments have failed or your spending
   limit needs to be increased."* Underneath that, every `Package.swift` floors at
   `.macOS("26.0")` and every runner is `macos-15`, so the matrix could not pass on
   GitHub-hosted images even when paid. The user chose (9C) to leave CI as it is.
   **`./scripts/verify.sh` is therefore the only gate**, and every phase runs it in
   full before committing and pastes its summary into the changelog.
3. **The local gate is green.** `verify.sh fast` passed on this machine (Xcode 26.6,
   macOS 26.5) at the start of this pass: all eleven stages.

## The decisions, and where each lands

| # | Decision | Phase |
|---|---|---|
| 1A | A per-window `CollectionReadModel` (the `SpaceModel` shape) with an injected fetcher — collection feed or saved-search feed; `IngestionModel` keeps writes and undo | P3 |
| 2A | `AtelierExport.TextStyle` gains family / weight / alignment; `MoodboardRenderer` honours them; a conformance test drives both bridges with one fixture set | P0 (package), P1 (test) |
| 3A | `CaptureAuth` takes `allowedOriginSchemes` as data; `pinnedExtensionID` stays Chrome-only; the negative matrix covers `safari-web-extension://` | P0 |
| 4A | `SearchRules(query:)` / `LibrarySearchQuery(rules:)` with a round-trip test and an exhaustiveness test over every stored property | P1 |
| 5A | One tree builder, in `AtelierBrowse`. Dead `FolderNode` deleted; `CollectionNode.tree` becomes a projection of the cycle-safe tree | P7 (after 098 · P4) |
| 6A | `AtelierError: LocalizedError` with an exhaustive prose table; the silent `try?` sites log; the `apply*` / `perform` boilerplate collapses inside 1A | P0 (Core), P1 (app), P3 (collapse) |
| 7A | The saved-searches sidebar section is SwiftUI (no reorder → no `NSOutlineView`); the generic-coordinator trigger is written down | P4 |
| 8A | `Debug/` and `Spike/` behind `#if DEBUG`; the bake-off delegate adaptor is DEBUG-conditional; `-library-root` survives as the environment key only; `verify.sh` adds a Release build | P1 |
| 9C | CI stays red; `verify.sh` full is the phase gate | every phase |
| 10A | A minimal macOS XCUITest smoke target, seeded through `ATELIER_LIBRARY_ROOT`, run from `verify.sh` full | P2 (target), P5 / P6 (flows) |
| 11A | Test-visible completion signals replace fixed sleeps; one shared `poll` helper | P1 |
| 12A | `AtelierArchive` gains committed fixtures + a loader; every importer ships a sanitised real export, a hand-composed minimal fixture, and negative fixtures | P0 (infra), P17–P19 (parsers) |
| 13A | A `Coalescer` behind `refreshAfterIngest`; 071 · Phase 0 measurement; the narrow summary row only if decode dominates | P3 |
| 14A | `setGridOrder` as one chunked `CASE` statement that ignores non-members; the app's membership pre-read goes; a harness row | P0 (Core), P3 (app) |
| 15A | A semantic-search harness row; a resident corpus cache only if 20k measures over ~100 ms | P0 (row), P0b (cache, conditional) |
| 16A | Launch orphan GC runs on a `gc-pending` marker. **The reaper half is withdrawn — see 18A below.** | P1 |
| 18A | The undo-window reaper is not viable as specified; the marker half stands alone | P1 (closed) |

Three directions the user set for the plan itself: the work happens on **`feat/mac-backlog` in a git worktree**; phases run **sequentially, one agent each**; the importer parsers run only once **`resources/<eagle|raindrop|pinterest>/` exists** (the user will supply real exports).

## The rules every phase agent works under

These are the brief's fixed part. The phase sections below are the variable part.

- **Where.** The worktree at `../ref-atelier-mac` on branch `feat/mac-backlog`, created
  from `3bf4d7e`. Never the main checkout; it belongs to the 098 session and is dirty.
- **The gate.** `./scripts/verify.sh` (full mode) green before the commit. The summary
  block is pasted verbatim into the changelog. A phase that cannot get the gate green
  does not commit; it reports.
- **`xcodebuild -list` after every `project.pbxproj` write** (098's rule), and a
  second `verify.sh` after it.
- **One changelog, one commit.** The changelog index is allocated at commit time from
  `ls .change-log | tail -1` (the 098 session allocates too; a collision is renumbered
  at rebase). The format is the narrative one [455](../.change-log/455-what-the-move-found.md)
  and [456](../.change-log/456-the-plan-reviewed-with-the-user.md) use: what was
  found, what was decided, what is still NOT covered. The commit message is
  `[type]: [scope] - [message]`, at most 80 characters, no filler.
- **`git add` names its paths.** Never `-A`.
- **Tests are Swift Testing** (`@Test` / `#expect`), in the suite style of the package
  touched. Every new pure function has a test; every new error path has a test; every
  new `try?` has a log line beside it or is a `do/catch`. No `Task.sleep` as a wait —
  await a signal (11A).
- **The sixteen decisions are constraints.** An agent that finds one of them wrong
  stops and reports; it does not choose differently.
- **The report** at the end of the phase names: files changed, tests added (count and
  names), the `verify.sh` summary, the changelog number, the commit hash, and *what is
  still NOT covered* — the paragraph every 098 changelog closes with.
- **Docs.** The phase updates the status row for itself in this file. A phase that
  amends a decision recorded in another doc amends that doc's status block too.

## P0 — package foundations

*Core, Server, Export, Archive. No app-target files. Decisions 2A, 3A, 6A (Core), 12A
(infra), 14A (Core), 15A (row). Effort M.*

- **2A.** `AtelierExport.TextStyle` gains `fontFamily: String?`, `weight`, `alignment`
  (its own enums, `rawValue`-matched to `AtelierCore.TextWeight` / `TextAlign` the way
  `CanvasRenderer`'s are). `MoodboardRenderer` (`Render/MoodboardRenderer.swift:210`)
  stops hard-coding Helvetica: a font descriptor from family + weight, the system font
  when family is nil, alignment through the paragraph style. `RenderOptions` unchanged.
  Tests in `AtelierExportTests`: family / weight / alignment each change the raster
  (pixel probe, the suite's existing style); an unknown family falls back to the
  system font; `FrameStyle.label` inherits the same fields.
- **3A.** `CaptureAuth.init(token:allowedOriginSchemes:pinnedExtensionID:)` with the
  default `["chrome-extension"]`. `isAllowedOrigin` parses the scheme from the origin
  rather than `hasPrefix`. `pinnedExtensionID` applies to the Chrome scheme only. Tests
  (`CaptureAuthTests`): a listed second scheme is accepted, an unlisted one rejected,
  the pin does not apply to it, a malformed origin (no `://`) is rejected, an absent
  origin still needs the token. `CaptureServerIntegrationTests` gains *bind twice → the
  second `start()` throws* (the untested port-in-use path).
- **6A (Core).** `AtelierError: LocalizedError`. `errorDescription` is a `switch` with
  **no `default`**, so a new case fails to compile until it has a sentence. A test
  enumerates every case (a hand-listed array — the enum carries payloads) and asserts
  a non-empty, non-debug-description sentence for each; a second test asserts the
  array's count against the case count read from the source file, so the list cannot
  silently fall behind.
- **12A (infra).** `AtelierArchive/Package.swift` gains `resources: [.copy("Fixtures")]`
  on the test target; `Tests/AtelierArchiveTests/TestSupport/Fixture.swift` provides
  `fixture(named:) -> Data` and `fixtureURL(named:)`; one smoke fixture proves the
  wiring. Existing in-code fixtures are left alone.
- **14A (Core).** `setGridOrder(collectionID:orderedAssetIDs:)` becomes chunked
  `UPDATE collection_item SET manual_order = CASE asset_id WHEN ? THEN ? … END WHERE
  collection_id = ? AND asset_id IN (…)`, chunk size 500 (SQLite's variable limit is
  the reason for the chunk, and the test says so). Ids that are not members are
  **ignored**, and the doc comment says so; the `.notFound` for a missing collection
  stays. `ScaleHarnessTests` gains a `setGridOrder` row at every N.
- **15A (row).** `ScaleHarnessTests` gains a `semanticSearchAssets` row: seed one
  512-float embedding per asset at each N, time a query. The changelog reports the
  numbers. **If 20k is over ~100 ms, P0b is scheduled; if not, it is not.**
- **`AppServices.swift` split** (a pure move, no semantic change): `AppServices.swift`
  keeps the class, the funnel, and the private helpers; `AppServices+Collections.swift`,
  `+Assets.swift`, `+Spaces.swift`, `+Search.swift`, `+SavedSearches.swift`,
  `+Analysis.swift`, `+Jobs.swift`, `+Library.swift` take the MARK sections. A
  `require<T: FetchableRecord & TableRecord>(_:db:key:entity:) throws -> T` helper
  replaces the 23 `fetchOne … else throw .notFound` guards. The `swift test` suite is
  the proof; no test changes.

**Verify:** `verify.sh` full. **Out of scope:** any file under `AtelierRefs/`.

## P0b — the semantic corpus cache (conditional on P0's number)

*Runs only if P0's harness row says so. Effort M.*

A `Sendable` corpus cache in Core keyed by `modelVersion`: `ids: [UUID]`,
`matrix: [Float]` (row-major, 512 wide), loaded on first query, invalidated from the
two write-funnel sites (`upsertEmbedding`, asset delete) — the only two writers.
Scoring by Accelerate dot products; top-k by partial selection, not a full sort; the
structured scope applied as an id-set intersection after the SQL pre-filter the query
already runs. The harness row is re-run and both numbers go in the changelog. Memory is
stated: 2 KB × N, resident.

## P1 — app-target foundations

*`AtelierRefs/` only, and none of the files 098 · P4 touches. Decisions 4A, 6A (app),
8A, 11A, 16A, plus the noted items. Effort M–L.*

- **4A.** `SearchRules.init(query: LibrarySearchQuery)` and
  `LibrarySearchQuery.init(rules: SearchRules)` in the app target, beside
  `LibrarySearch.swift`'s query type. The round-trip test. The exhaustiveness test: a
  `Mirror` over `LibrarySearchQuery` asserts every stored property is either mapped or
  named in an explicit `notPersisted` allowlist (`tagNameContains`, plural
  `collectionIDs` beyond the first, `sort`) — the test fails the day a field is added
  to one side. The plural-scope rule (a saved search is single-collection, 015) is
  asserted, not assumed.
- **2A (test).** `StyleBridgeConformanceTests` in `AtelierRefsTests`: one fixture set
  of `ElementStyle`s (nil family, each weight token, each alignment, an unknown weight
  token, the legacy `resizeMode`, `textAutoWidth`) driven through
  `ElementRendering.textStyle(for:)` and `MoodboardExport.textStyle(from:)`, asserting
  field-for-field equivalence. `ColorPalette.rgb(fromHex:)` joins `HexGrammarTests` as
  a fourth parser (6-digit inputs only; the test says why).
- **6A (app).** `IngestionModel.message(for:)`, `SpaceModel.message(for:)` and the
  three controller copies collapse to `error.localizedDescription` plus the genuinely
  surface-specific overrides (the "that space" / "that folder" phrasings), each
  override tested. The `try?` sites at `IngestionModel.swift:805`, `:810`, `:3345`,
  `:3387` and the twelve in `SnapshotManager.swift` get an `AppLog` line or become
  `do/catch`; the changelog lists each one and what it now says.
- **8A.** Every file under `Debug/` is wrapped in `#if DEBUG`; `AtelierRefsApp` installs
  the bake-off delegate through a five-line `AppDelegate` that forwards only in DEBUG;
  `CanvasRenderer/Spike/` is `#if DEBUG` (its only non-spike reference is a doc
  comment). `LibraryLocation` keeps `ATELIER_LIBRARY_ROOT` unconditionally (the UI
  tests need it) and honours `-library-root` in DEBUG only. `verify.sh` full gains an
  `xcodebuild build -configuration Release` stage so the guards are compile-checked;
  `ci.yml` is left as it is (9C).
- **11A.** `DetailImageLoader` and `ThumbnailPipeline` gain a test-visible completion
  signal (an `AsyncStream<Event>` the tests `await` on); `LibrarySearchModel`'s
  `resultsVersion` is awaited through the same shape. `poll` moves to
  `AtelierRefsTests/TestSupport/Poll.swift`; the two inline copies in
  `ThumbnailPipelineTests` go. `ShelfControllerTests` keeps its delays — the delay is
  the scenario. `BoundedWorkTests:131` awaits the recorder instead of sleeping.
- **16A.** `deleteAssetsRecoverable`'s caller writes `snapshots/.gc-pending`;
  `bootstrap()` runs `runOrphanBlobGC` only when the marker exists and removes it after
  a completed sweep. The undo-window reaper: when the undo stack evicts a
  `DeletedAssetsBackup` (or at `applicationWillTerminate`), the `BlobRef`s it holds are
  reaped by list — no enumeration. `runPostRestoreBlobReconcile` keeps the full walk.
  Tests: marker written on recoverable delete; GC skipped without it; GC runs and
  clears it with it; eviction reaps exactly the backup's refs.
- **Noted items.** `CaptureTokenStore` gains a `service:` parameter (default the
  production name) and tests for load / save / legacy-migrate against a test service.
  `CollectionDestinationList` and `DestinationPicker` take the `moveTargetsCache` memo
  the two other consumers already use, instead of rebuilding the tree per body pass.
  `applyOrder` (`IngestionModel.swift:1705`) drops its membership pre-read (14A's
  service now ignores non-members).

**Do not touch:** `CollectionTargets.swift`, `MasonryLayout.swift`,
`InboxDrainScheduler.swift`, `CollectionsOutlineView.swift` — 098 · P4's files. 5A's
first half waits in P7 for the same reason.

**Verify:** `verify.sh` full, including the new Release stage.

## P2 — the macOS smoke target

*Decision 10A. Effort M. pbxproj.*

- A new `AtelierRefsUITests` target. A DEBUG-only in-app seeder behind
  `-ui-test-seed <name>` (8A makes DEBUG-only launch arguments the rule) that
  populates the library at `ATELIER_LIBRARY_ROOT` with a small fixture set: three
  collections (one nested), one space, four assets, one saved search.
- Flows, smoke only, no layout assertions: launch → the main window exists and shows
  the seeded collection; ⌘, → a Settings window exists; the sidebar lists the three
  collections in order. ⌘K and the palette add their flows in P5 and P6.
- `verify.sh` full runs it (`-only-testing:AtelierRefsUITests` as a second app stage,
  so a UI failure is named separately from a unit failure). `ci.yml` is left alone.

**Verify:** `verify.sh` full; `xcodebuild -list`.

**Done** ([468](../.change-log/468-the-mac-gets-a-window-a-keystroke-and-an-order.md)).
Two bullets above were written before 098 landed and 467 replaced them: the seeder's
argument is **`-seed-fixture-library`**, 098's spelling and its three guards, not
`-ui-test-seed <name>`; and the Mac target had **zero** accessibility identifiers, so
adding the four the flows need was most of the phase. Both flows that touch the app —
⌘, and the sidebar's disclosure — needed `app.activate()` first: on macOS a key event
goes to the frontmost app, and a click into an inactive window is eaten by activating it
unless the view accepts the first mouse (`NSTableView` does, `NSButton` does not). The
`verify.sh` stage is `App target (UI)` and signs **ad-hoc**, because a UI-test runner
built with `CODE_SIGNING_ALLOWED=NO` is SIGKILLed before it connects. `full` was
fourteen stages — **amended 2026-09-03: the UI stage was removed from the gate again
(issue 23D, [474](../.change-log/474-the-gate-stops-claiming-a-window.md)); `full` is
thirteen and the suite runs by hand as `verify.sh ui`.**

## P2b — the thumbnail suites' intermittent failure

*Unplanned. Issue 20A, authorised by the user after the flake blocked two gate runs.
No decision in the table above covers it. Effort S.*

**Why an unplanned phase exists.** `verify.sh full` is the only gate (9C), and it was
failing roughly one run in four for a reason no phase owned. When it went, it went the
same way every time: `ThumbnailPipelineTests` and `ThumbnailWindowPrefetcherTests`
failing **together** — about 42 issues across 15 tests — with the other ~1,690 cases in
the target green. [465](../.change-log/465-the-corpus-goes-resident.md) hit it on its
second gate run and [468](../.change-log/468-the-mac-gets-a-window-a-keystroke-and-an-order.md)
on its first, and both wrote it up as somebody else's. A gate that fails once in four
runs for no stated reason is a gate that stops being read, which is the road
[464](../.change-log/464-the-gate-tells-its-two-arms-apart.md) exists to get off — so
the user took it out of the backlog and made it its own phase, ahead of P3.

The obstacle was that the failure was **illegible**: `xcodebuild`'s log records one
`Test case '…' failed` line per test and no assertion text at all. The first job was to
get the text, with `-resultBundlePath` and `xcrun xcresulttool get test-results summary`,
which prints the `failureText` Swift Testing actually recorded. That is the tool the next
flake should reach for first.

**Verify:** the failure reproduced before the fix; the affected suites run ≥10 times
consecutively after it; `verify.sh` full.

**Done** ([469](../.change-log/469-the-cache-that-was-never-promised.md)). The text says
every cache read returned `nil` for a key whose decode had provably run — eight
one-megabyte entries under a sixty-four-megabyte budget, **zero** resident. The suites
were asserting residency against an `NSCache`, which documents that it does not promise
it. Production keeps `NSCache`; the two suites get a `ThumbnailStore` seam and a
deterministic store behind it. **No production behaviour changed.**

## P2c — the detail-image cache stops asserting residency

*Unplanned. Issue 21A, authorised by the user immediately after P2b. No decision in the
table above covers it. Effort S.*

P2b's changelog closed by naming what it had deliberately left: `DetailImageCache` is a
second `NSCache`, and its tests make the same bet against it that fifteen thumbnail tests
were making — `resident(8, in: roomy) == 8` is word-for-word `costBasedEviction`'s
sentence. **Neither suite has ever been observed to fail.** That is not evidence they
cannot: their insert-then-read windows are microseconds of straight-line code where the
thumbnail suites' were seconds across task hops, which narrows the window rather than
closing it. The user took it as its own small phase (21A) on the grounds that the seam
that fixes it was already built and paid for.

The instruction that shapes this phase is *reuse*: if `DetailImageCache` can be expressed
through `ThumbnailStore` / `PinnedThumbnailStore`, it must be, because a second protocol
saying the same three sentences is exactly the duplication this plan exists to remove.

**Verify:** the evidence is structural, not a green run — no assertion in the affected
suites may read residency from an `NSCache`. Then ≥10 consecutive runs of those suites, a
tally that is *consistent with* the bug rather than a refutation of it, and `verify.sh`
full.

**Written, NOT committed — the gate is red on a stage this phase does not touch**
([470](../.change-log/470-the-second-cache-takes-the-same-seam.md)). Ten assertions across
eight tests were residency-dependent — two more than 469 predicted, in a suite it did not
name (`DetailSessionTests`, where a neighbour preload skips only on a cache hit, so
`probe.buckets("prev") == [3072]` is a cache read wearing a probe's clothes). The existing
seam fitted: `DetailImageCache` is now the `DetailImageKey`-shaped face of a
`ThumbnailStore`, and the protocol gained one rule (1b, a count budget) rather than a
twin. **No production behaviour changed.**

**`✗ App target (UI)` blocks the commit, and the diff is not the cause.** All three smoke
flows hang the app's main thread for 30 s inside `SecItemCopyMatching` —
`IngestionModel.bootstrap` → `loadOrCreateCaptureToken` → `CaptureTokenStore.readKeychain`
— on a **login-keychain** item whose ACL is bound to the reading binary's code signature.
The UI stage is the one stage that signs ad-hoc (468, and it must), so every rebuild of
the app presents a new signature, macOS raises a `SecurityAgent` confirmation, and an
unattended `xcodebuild` never answers it. With every change of this phase stashed — a tree
identical to `f91f29d` — a fresh-`derivedDataPath` rebuild of **HEAD fails all three flows
the same way**, while re-using the already-authorised binary passes. So this blocks
**every** future phase that touches an app-target file, until either the prompt is
answered at the machine or `CaptureTokenStore` stops doing a blocking, cdhash-scoped
keychain read on the main actor at launch. The second is a production change and no
decision here authorises it; **the user decides.** The other thirteen stages pass,
`App target` included.

## 22A — the capture token leaves the main actor · **done** ([471](../.change-log/471-the-token-leaves-the-main-actor-at-launch.md))

*Unplanned. Authorised by the user after P2c reported the blocker and stopped. No decision
in the table above covers it. Effort S.*

[470](../.change-log/470-the-second-cache-takes-the-same-seam.md) diagnosed the UI stage's
hang and left the fix as a judgement for the user: `IngestionModel.bootstrap()` blocked the
main actor at every launch on a synchronous `SecItemCopyMatching` against a login-keychain
item whose ACL is bound to the reading binary's code signature. The user took the option
470 had argued for on its own merits — **take the blocking read off the launch path,
because it is a hang a real user can hit and not only a test** — together with a DEBUG
launch argument so the smoke suite stops starting an endpoint none of its flows asserts.

**What forced the hop was not the caller, and that is the finding.** The app target
compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so `CaptureTokenStore`'s statics
were *implicitly* `@MainActor`: the store WAS main-actor code, and the obvious fix —
awaiting it from a background task — would have hopped **onto** the main actor and blocked
it in the same place. And because the target also sets `SWIFT_APPROACHABLE_CONCURRENCY =
YES` (`nonisolated(nonsending)` by default, SE-0461), `nonisolated` plus `async` still runs
on the caller's actor. **`@concurrent` is the load-bearing token**, and it is measured
rather than asserted: deleting it fails exactly one test, the one that watches which thread
the store ran on.

**Production behaviour DID change, deliberately.** The app no longer blocks its main thread
on `securityd` at launch — this entry does not get to say "nothing changed", and does not.
Everything the token itself does is identical: same service, same first-run mint, same G6
migration, same value returned.

`-skip-capture-endpoint` is DEBUG-only (8A), spelled the way 098's `-seed-fixture-library`
is, and goes **last** in `SmokeUITests.launch()` behind the `-key value` trap that file
already documents. The keychain prompt itself is not retired — only the data-protection
keychain would do that, and that is a migration of every existing user's token, not a flag.

**The gate is green, and P2c's commit follows immediately against this same gate run** —
the two were verified together, which is how [471](../.change-log/471-the-token-leaves-the-main-actor-at-launch.md)
describes it.

## P3 — the per-window read model · **done** ([472](../.change-log/472-the-feed-gets-a-model-of-its-own.md))

*Decisions 1A, 6A (collapse), 13A, 14A (app). The largest phase. Effort L.*

**Landed as specified, with one deliberate omission and one count corrected.**
`CollectionReadModel` owns the feed and every derivation; `IngestionModel` keeps
computed forwards (not storage) so ~300 call sites did not churn, and republishes the
read model's `objectWillChange` as its own. The eight `apply*` workers, both `perform`
overloads and the dead `mutateContents` collapsed into one
`performWrite(focus:reload:_:)`. **The reload-site count was 67, not 69** (69 predates
P1 and P7); **47 of them — 26 `loadContents` + 21 `refreshFolders` — are the
collection-feed reloads this phase replaced**: 41 became `publishChange(_:)`, six survive
deliberately (bootstrap ×2, `requestJumpSelection`, `createFolder`'s select-on-create,
`setSortMode`'s optimistic reload, `flushViewBumps`' failure fallback), and the 20
space/backup/sweep refreshes were never in scope.

**071 · Phase 0a ran, and closed its own gate negatively.** At 20,000 rows the read
splits 3.2 % query / 8.5 % row decode / **82.2 % struct decode** / 0.7 % publish, of
which `raw_metadata` is 128 ms — **20 % of the total, not a majority**. 071 §3's
hypothesis (decode dominates the scan) is confirmed by 26×; the narrower gate this
phase was given (`rawMetadata` dominates) is not met, so **§6.1's narrow summary row
was NOT built**. The numbers, and the two things they do warrant, are in the changelog
and in [071](071-grid-scale-paging-plan.md)'s status block.

- **`CollectionReadModel`** (`@MainActor final class`, `ObservableObject`): owns
  `items`, `subfolders`, `loadedCollectionID`, `contentsVersion`, and the derived
  indexes `rebuildItemDerivations` builds today. `load()` with the load-id race guard
  as it is. The fetcher is injected: `.collection(services)` reads
  `collectionItems(in:sort:includeArchived:)` + `childCollections`; `.savedSearch(services)`
  reads `evaluate(rules:)` and carries no memberships. Rows are the type the search
  results grid already consumes; a collection feed carries membership, a saved-search
  feed does not, and every manual-order affordance keys off membership presence
  ([057](057-smart-collections-overview.md): a saved search has no manual order).
- **`IngestionModel` keeps writes, undo, selection.** `items` / `loadContents` /
  `selectedFolderID`'s content role move to the main window's read model. The model
  publishes a `libraryChanged(collectionID: UUID?)` subject; read models subscribe and
  reload when the id matches or is nil. The 69 internal reload sites become one
  `publishChange(...)`.
- **The boilerplate collapses (6A).** The eight `apply*` workers and two `perform`
  overloads become one `performWrite(focus:reload:_:)`. Navigation state is no longer
  mutated from inside undo inverses; the inverse publishes a change and the focus
  intent, and the window that owns the read model decides.
- **13A.** `ViewBumpCoalescer` generalises into `Coalescer<Key>`; `refreshAfterIngest`
  runs behind it at ≤1 reload per 500 ms per collection. 071 · Phase 0a: the harness
  splits `collectionItems` into query / row decode / publish at every N; the numbers
  go in the changelog. **If `rawMetadata` decode dominates, 071 §6.1's summary row
  lands in the read model in this phase; if not, the changelog says so and stops.**
- **14A (app).** `applyOrder`'s pre-read is gone (P1 did it); this phase confirms the
  reorder path through the read model.
- **Tests.** `CollectionReadModelTests`: load; a superseded load never publishes;
  selection pruned to survivors; fetch failure → `lastError` (via `localizedDescription`);
  the saved-search feed; a change event reloads only a matching id; the coalescer
  collapses a burst (awaited through a signal, 11A). The `IngestionModel` suites that
  read `items` re-point to the read model without weakening an assertion; the count of
  `@Test`s does not go down.

**Out of scope:** the palette, ⌘K, any new surface. **Verify:** `verify.sh` full.

## P4 — smart collections

*Decisions 4A, 7A, 1A. Honours [057](057-smart-collections-overview.md) as written.
Effort M.*

- `SidebarItem.savedSearch(UUID)`, a `NavModel` route, and a **SwiftUI** "Smart"
  section in `SidebarView` below Spaces: flat, rename inline through
  `SidebarEditState`, delete through the context menu with the shared confirmation,
  **no reorder**. The trigger for a generic outline coordinator is recorded in the
  changelog: *a third reorderable sidebar list*.
- The grid is the read model's saved-search feed. Sort = 007's modes minus `.manual`;
  drag-reorder disabled; drag-out and drag-to-move still work; an item that stops
  matching mid-triage vanishes on the next reload, and the selection is pruned (057's
  test).
- **"Save this search…"** in `LibrarySearchable`'s toolbar, enabled only when the
  query is non-empty, through the 4A initialiser and `NameEntryAlert`. Re-saving from
  an open smart collection updates the rules (057: the search field *is* the rule
  editor).
- Badges: *references a deleted tag* (`savedSearchMissingTags`) and *can't read this
  search* (`invalidSavedSearchRules`), both on the sidebar row and the grid header.
- Excluded from every destination list, menu and drop target (`CollectionTargets`
  consumers, `CanvasDropRouter`, the rail) — asserted. Home gallery cards after the
  real collections with a distinct tint. `KeyMap` rows. The archive manifest already
  carries `saved_search` rows ([081](081-backup-plan.md)); the phase confirms round-trip
  in `LibraryArchiveRoundTripTests` and adds the case if it is missing.
- Tests: `SavedSearchesSidebarModelTests` (list, rename, delete, badges, reconcile on
  delete), the search-model save path, the exclusion assertions.

**Verify:** `verify.sh` full.

**Done** ([473](../.change-log/473-the-saved-search-becomes-a-place.md)). Landed as
specified — the SwiftUI section, the read model's saved-search feed with 007's modes
minus `.manual`, "Save this search…" (which re-rules the OPEN smart collection rather
than making a second one), both badges on both surfaces, the exclusion assertions, the
Home cards and a `KeyMap` row for ⌘S. **The trigger recorded for a generic outline
coordinator is *a third reorderable sidebar list*** — two is not a pattern, and this
section is not the third because it does not reorder at all. P3's three handoffs are
all closed: the badges have a path, `dragPayload` stamps the FEED's id instead of the
import target, and the coalescer's trailing run is `[weak self]` plus a cancellable
handle (`Coalescer.cancelTrailing`).

**One bullet above is FALSE and this phase is where it was found.** *"The archive
manifest already carries `saved_search` rows ([081])"* — it does not, and
[081](081-backup-plan.md) never said it did; the claim is
[057](057-smart-collections-overview.md)'s alone. It was not simply added, because
`ArchiveManifest.TagEntry` deliberately carries **no tag id** ("an importer mints its
own") while `SearchRules` references tag ids — so a rules blob copied into a second
library would point at ids that exist in neither its tag nor its collection table.
Making it portable needs a rule-remapping design no doc specifies. The gap is asserted
instead (`savedSearchesDoNotYetCrossTheArchive`), so the day someone adds the rows the
test forces them to say what they did about the ids.

**The gate passed at exit 0 on its first run and the machine has since stopped launching
the app under test.** `App target (UI)` went red after the code was already verified, and
a control run with the whole phase STASHED — a tree identical to `e4181e1` — fails all
three smoke flows with `"the app opened no window"`, one MORE than it fails with the diff
applied. That is 470's ad-hoc-signing blocker returning: this is the one stage that must
sign ad-hoc (468), every rebuild presents a fresh signature, and an unattended
`xcodebuild` cannot answer what the system raises. **Every phase from here that rebuilds
the app will see a red `App target (UI)` on this machine until the prompt is answered at
the keyboard or the login session is restarted** — the other thirteen stages, `App target`
and `App target (Release)` included, are green on every run. See
[473](../.change-log/473-the-saved-search-becomes-a-place.md)'s gate section for the
six-run sequence and the control.

## P5 — the ⌘K quick switcher

*Answers 011 · U4's open question: **its own surface, the shared ordering.** Effort M.*

- `SwitcherModel` (pure, tested): candidates are collections (by tree path, from
  `CollectionTargets.destinationTree`), spaces (`SpaceTargets.ordered`), saved searches,
  and the fixed destinations Home / Capture / Shelf. Fuzzy match with a documented
  ranking (prefix > word-start > substring; recents first; ties by the shared order).
  A small MRU in `UserDefaults`, namespaced by library id like the clipboard
  preference. **Verbs ("New Space", "Snapshot Now") are not in v1** and the changelog
  says why: they have menu items with key equivalents already.
- `SwitcherPanel`: a SwiftUI view in an `NSPanel` over the shell, opened by ⌘K
  (`KeyMap` + a View ▸ *Go to…* command). ↑ / ↓ / Return / Escape; selection routes
  through `NavModel.selectSidebar`; first responder is handed back on close, the
  `DestinationPicker` discipline. Inside the detail overlay and on a Space board the
  panel still opens; the destination it commits pops the overlay first.
- The smoke target gains: ⌘K → type the nested collection's name → Return → the grid
  shows it. **This flow is written but NOT gated** — [474](../.change-log/474-the-gate-stops-claiming-a-window.md)
  took `App target (UI)` out of `verify.sh full`, so nothing runs it unless a person
  types `./scripts/verify.sh ui`. The model tests carry the weight instead.

**Verify:** `verify.sh` full.

**Done** ([475](../.change-log/475-the-switcher-is-its-own-surface.md)). 011 · U4's open
question is answered as planned — its own surface, the shared ordering — and the ranking
it is built on is written down where it is implemented: **prefix > word-start >
substring, then recents (most recent first), then the shared ordering**, with each tier
and each sort key carrying its own test. The MRU is `library.<id>.switcherRecents`,
matching `ClipboardWatcher.enabledKey(libraryID:)` (016 §C). Verbs are not in v1 and the
changelog says why. **The ⌘K smoke flow was written and could NOT be observed passing:**
`verify.sh ui` fails all four flows with *"the app opened no window"*, and a control run
with this phase STASHED fails the unchanged launch flow the same way — 474's blocker, on
`HEAD` as much as here.

## P6 — the floating reference palette

*Honours 011 · Cluster D: read-only + drag-out, one window, a picker. Effort M–L.*

- A `Window("Reference Palette", id: "palette")` scene with `.windowLevel(.floating)`,
  a compact default size, resizable, hidden title bar to match the shell. Opened from
  View ▸ *Show Reference Palette* (key from `KeyMap`, chosen there against the existing
  map) through `@Environment(\.openWindow)`, and from a sidebar row's context menu
  (*Open in Palette*). One window: a second open focuses it.
- `PaletteModel` owns a `CollectionReadModel` (collection or saved search) and the
  picker state; the picker reuses P5's `SwitcherModel` ranking — one search over
  destinations, two surfaces. Remembers what it last showed, per library.
- The grid is `MasonryGridHost` in a read-only configuration (`GridHostConfiguration`
  gains the flags): no selection, no context menu, no keyboard verbs; drag-out only,
  through the existing `AssetDragPayload` + file promise. A space in the palette is
  **not** in v1; the changelog names it as the follow-up and why (the canvas host
  assumes an editing model).
- The smoke target gains: open the palette → a second window exists at floating level
  → pick the nested collection → it shows a different collection than the main
  window. **Written but NOT gated**, as P5's flow is: `App target (UI)` left
  `verify.sh full` in [474](../.change-log/474-the-gate-stops-claiming-a-window.md), so
  a flow added here runs only under `./scripts/verify.sh ui`, by hand. Say so in the
  changelog rather than implying coverage; and put the real assertions in `swift test`.

**Verify:** `verify.sh` full.

**Done** ([476](../.change-log/476-the-palette-is-the-second-window.md)). The backlog's
claim was verified before anything was written and it was TRUE: `AtelierRefsApp` declared
one `WindowGroup` and the standard `Settings` scene, and nothing else. It now declares a
`Window("Reference Palette", id: "palette")` — a `Window` and not a `WindowGroup`, which
is what makes 011's *one window, one focus* a property of the scene graph rather than a
rule someone enforces. The key is **⇧⌘P**, chosen against `KeyMap` after P5's ⌘K
(`shiftCommandPIsTheReferencePalette`); plain ⌘P is deliberately left to Print and
`commandPIsFree` says so. `GridInteraction` (`allowsSelection` / `allowsContextMenu` /
`allowsKeyboard`) is the read-only shape, defaulted to `.full` so no existing grid
changed, and drag-out is deliberately NOT one of the flags. The picker is P5's
`SwitcherModel` over P5's `SwitcherRanking` with ONE addition — `PaletteDestinations
.canShow(_:)`, a `switch` with no `default` — and the seams P5 needed were two words:
`SwitcherRow` became internal and took an `identifier`.

**The inherited handoff turned out to be load-bearing.** P4 fixed `dragPayload` to stamp
the loaded feed's id, but fixed it on `IngestionModel`, which reads exactly ONE read
model. A second window would have re-created the bug one level up — a drag out of the
palette carrying the MAIN window's collection, which `routeDrop` reads as a MOVE. The
rule moved down to `CollectionReadModel.dragSourceID`; `IngestionModel` forwards and
`SmartCollectionView` stopped spelling the sentinel itself.

**The smoke flow is written and, as P5's was, could not be observed**
(`testShiftCommandPOpensTheReferencePalette`): `App target (UI)` is out of the gate (474)
and `verify.sh ui` cannot run at all on this machine (issue 23C). Two things it would not
have asserted anyway are named in the flow's own doc comment: `.windowLevel(.floating)`
has no accessibility surface, and "a second ⇧⌘P does not spawn a second palette" is a
property of `Window` rather than of any code here.

## P7 — rebase onto 098 · P4, and the tree that lives in Browse · **done** ([467](../.change-log/467-four-builders-and-the-numbers-that-collided.md))

*Decision 5A. Scheduled after P6; the user resequenced it to run after P1 (issue 19A),
because 098 closed and every later phase would otherwise have been written against a tree
32 commits stale. Effort S.*

- `git rebase feat/ios-ingest`; conflicts resolved; changelog numbers renumbered
  where the two sessions collided; `verify.sh` full on the result.
- `FolderNode` and `folderTree` are deleted (no consumer). `CollectionNode.tree` becomes
  a projection of the Browse-owned, cycle-safe tree. A test feeds a corrupt
  parent cycle to the sidebar's tree and asserts it terminates. `MasonryLayout` is
  confirmed to read `MasonryColumns`' constants (P4's work); if P4 left a copy, it
  goes.

**Done:** rebased onto `395e471`, three conflicts (`AtelierArchive/Package.swift`,
`AppServices.swift`, the phone's `LibraryStore.swift`). 098 · P4 had already collapsed
`CollectionTargets.destinationTree` into `BrowseCollectionTree.tree` and left no duplicate
of `MasonryColumns`' constants, so 5A's remaining half was the two builders in the app
target. **P2's brief is rewritten** — see 467's *P2's ground truth* section: the macOS
target does not exist, 098's `-seed-fixture-library` shape replaces the planned
`-ui-test-seed <name>`, the Mac has **zero** accessibility identifiers to assert on, and
098's gate is `ci.yml`-only so P2's `verify.sh` stage is neither superseded nor in
conflict.

## P8 — the detail page's post: the pile, the chip, the Post row

> **Status: this phase was already built, and the plan below was written from two stale
> status lines.** Audited file by file in
> [479](../.change-log/479-the-phase-that-had-already-shipped.md): every deliverable
> named here has been in the tree since **2026-08-10** — `fd2d933` (the chip),
> `6b637cc` (`fitRect` + the pile), `b9ed033` (the position moves to the sidebar),
> `0a72463` (a slot per member), changelogs 356–359. **Increment 3, the spread this
> section says is "judged after these ship", shipped too** — 360, with 361–363 fixing
> its position, its scrub and its hit region. 080's own §3.3 and §3.5 already said so;
> only its header, and 078's, still read "unbuilt". No code was written for P8; the
> commit is the correction to these three docs.

*[080](080-detail-fan-carousel-plan.md) increments 1–2 as settled, plus
[078](078-item-detail-gaps-plan.md) I4's chip. Effort M.*

`ItemDetailPost`; the fitted artwork rect; the `⧉ 2 of 4 in this post` chip beside the
pager; the sidebar's "Post" row; the resting pile with no images (080 §3.4). The fan
**spread** (080 §3.5) is judged after these ship, as 080 says. Video and tweet members
ride the same post model — the backlog's "fan carousel for video and tweet members"
is this phase's I2, not a separate feature. Tests per 080 §5.

**What the audit found the phase does NOT close.** The chip beside the pager and the
sidebar row are one fact and two chromes, not two deliverables: 358 replaced the first
with the second after seeing it on screen. Video and tweet members ride the post model as
**members** — counted, slotted, walked onto, jumped to — but `fanPile` and `fanSpread`
are gated on `isImage`, so a video **on the page** gets the Source row and no pile or
arc, and the row's copy says "Image" whatever the member's kind. Both are 080 §7's
reserved judgement, still open.

## P9 — the detail page's remaining gaps

*Effort M.*

- **The bottom filmstrip** ([041](041-item-detail-redesign-plan.md) deferred it):
  five neighbour thumbnails through `DetailImageLoader`'s preload window, the
  `Palette.filmstrip` token already reserved.
- **Repost and thread on X posts:** `rawMetadata.repostedBy`, `threadId`,
  `threadIndex` are stored and never rendered. A `SourceSection` row each, read through
  `JSONValue`; nothing new is stored.
- **Detail on a Space board:** the phase reads
  [023](023-item-detail-plan.md) F3b ("open from Space canvas") against the code and
  scopes what is actually missing — the backlog names it, the docs say it shipped, and
  the agent settles which is true before writing anything.

## P10 — the color filter's "match all"

*Effort S.*

An *Any / All* control in `ColorFilterPicker`; `LibrarySearchQuery.colorMatch`;
carried through the 4A initialisers into `SearchRules.colorMatch`; a `KeyMap` row;
tests for the query and the round-trip. The color wheel stays out: 085 says the stored
data cannot drive one.

**Done** ([478](../.change-log/478-the-colours-learn-to-say-and.md)). The backlog line
was read against the code first, and **`colorMatch` already existed everywhere except
the two places a user could reach**: `searchAssets` and `semanticSearchAssets` have
taken it since 085 · C1, `SearchRules` has stored it since C3, the SQL switches on it
and `evaluate(rules:)` passes it. What was missing was `LibrarySearchQuery.colorMatch`
— so every live query ran the service's `.any` default — and the 4A bridge, which
PINNED `.any` on the way into storage with a comment saying the query could not express
anything else. That comment was true when P1 wrote it and this phase is what made it
false. The exhaustiveness canary was confirmed to fail on the field before it was
mapped, with the sentence it was written to print. The chord is **⇧⌘C** (plain ⌘C is
Copy on two surfaces and a `.global` row would shadow both), and the control appears
only once two chips are on, because below two the modes select the same pictures. The
colour wheel stays out and [085](085-color-filter-plan.md)'s risk entry is amended to
say so at this phase's name rather than leaving it looking forgotten.

## P11 — the extension's one TODO

*Effort S. `extension/` only.*

`twitter.js:100`: a quoted-tweet photo inside the focal article leaks into
`mediaUrls`. Each photo anchor's `href` is `/<user>/status/<id>/photo/<n>` — the
per-photo status id the TODO asks for is already in the DOM. `mediaMatching` keeps a
photo only when its anchor's status id equals the focal `tweetId`. A case in
`extractors.test.js` from the `x-conversation.js` fixture: the quoted photo excluded,
the tweet's own photos kept. `npm run drift-check` unaffected.

**Done** ([477](../.change-log/477-the-anchor-says-whose-photo-it-is.md)). The rule landed
as described — a focal-article photo is kept only when its permalink anchor names the focal
`tweetId` — but **two sentences above are wrong, and the phase is where they were found.**

*"The per-photo status id … is already in the DOM"* is true of the page and false of the
pipeline: a harvested media item is `{ kind, src, width, height, alt, articleIndex }`, and
`mediaMatching` filters on `m.src`. No href was ever harvested, so the one-line filter this
section describes could not be written. The phase is three files — `harvestSignals` reads
`closest('a[href*="/status/"]')` into a per-photo `statusId`, `buildHarvest` carries it
beside `articleIndex`, and `twitter.js` filters on it — which is the shape
[026](026-tweet-single-capture-plan.md) · 5A specified for this exclusion in the first place.

*"from the `x-conversation.js` fixture"* names the wrong artifact. That file is a synthetic
**TweetDetail JSON** builder for the thread parser; it has no anchors and cannot produce a
harvest. The `/status/<id>/photo/<n>` shape is committed in `x-thread-detail.json` (a LIVE
capture, eighteen `expanded_url`s) and observed in `toStatusPermalink`'s own doc comment,
which exists because right-clicking a tweet's image hands the context menu that exact href.

The load-bearing decision is that the rule is **one-sided**: a photo is dropped only when it
positively names a DIFFERENT status, so a stale selector leaks a quoted photo (today's
state) instead of dropping the tweet's own (changelog 124's regression). The selector itself
is on `drift-check.js`'s live-verify list, because no fixture in this repo can hold it.
`npm run drift-check` was unaffected, as predicted: exit 2, staleness, no drift. **The
second P11 item — the Instagram drift-check hole named in the gate section below — was NOT
taken**; 477 is the TODO alone and says so.

**The gate did not reach exit 0, on two Swift stages this diff cannot reach.** Three phases
were building on the machine at once: `uptime` read load **16.85 / 24.62 / 23.96 on 8
cores**. `CanvasRenderer` failed two **frame-budget** assertions (9.38 ms against 8.33 ms)
and passes alone at 437 tests; `App target` failed a DIFFERENT set each run, every member a
bounded wait — 60.000 s hang timeouts, and the `LibrarySearchModelTests` cluster whose
`poll(timeout:)` default is 3 seconds. `App target (Release)`, the one stage that is a
compile rather than a clock, was `✓` on both runs, and this diff carries no Swift, no
`project.pbxproj`, and no file the Xcode project references. The App-target stage was re-run
once, per the brief, and not chased. Both blocks are in 477 verbatim.

## P12 — Spaces: zoom, arrange, snapping

*Effort M.*

- **Wheel zoom:** ⌘-wheel (and pinch stays) zooms about the cursor in
  `CanvasHostView.scrollWheel`, through the phase-bracketed path C7 built for pinch
  (`CanvasZoomGesture`), so the frozen-LOD rule holds.
- **Uniform grid arrange:** the phase verifies whether `CanvasArrange.Operation
  .reflowGrid` is already this and, if it is, closes the backlog line; if not, adds
  `.arrangeGrid` (equal cells, `SpaceSpacingPopover`'s gap), undoable like the rest.
- **Equal-spacing snapping:** while dragging, a guide when the moved tile's gap to a
  neighbour equals the gap between that neighbour and the next (`CanvasSnapping` gains
  the candidate; `SnapGuide` gains a kind), tested in `CanvasSnappingTests`.
- **Membership preview on moves:** the phase reads [066](066-spaces-gap-arrange-plan.md)
  and [076](076-spaces-tidy-wraps-plan.md) for what "membership" means on a board and
  scopes the smallest visible preview; if the docs do not define it, the agent reports
  rather than invents.

## P13 — Spaces: capture into a space, cross-screen drag

*Effort M–L. Touches server, extension, app.*

- **Direct capture into a space:** the capture DTO and `CaptureRoutes` accept
  `spaceID` beside `collectionID`; the route adds the ingested asset to the space at
  the next free slot. A new gated `GET /destinations` route lists collections (tree
  order) and spaces; the popup gains a destination picker over it (`popup-view.js`,
  pure and tested). Server route tests, `endpoint.test.js`, `popup-view.test.js`.
- **Cross-screen drag:** a tile dragged from the palette (P6) or the grid on one
  display onto a board on another. The phase measures what already works through
  `SpaceDragPayload` + `CanvasDropRouter` and fixes the gap it finds.

## P14 — Spaces: a per-frame ceiling

*[087](087-canvas-pinch-results.md) §7, option 1. Effort M.*

A spatial index (a uniform grid over world space is enough) so
`currentVisibleTiles()` is O(visible) rather than O(board); `CanvasBenchmark` and the
pinch harness re-run at 1k / 3.5k / 10k tiles; the numbers go in the changelog. Option
2 (one layer past a visible count) is scoped, not built, unless the numbers say the
cull was not the cost.

## P15 — browsing: a larger thumbnail tier

*Effort M. Gated by a size-on-disk number.*

`ThumbnailTier.xlarge = 2560`: generated by `IngestPipeline`, regenerated by
`ThumbnailBackfill`, removed by `MediaReaper`, chosen by the grid and by
`SpaceContent.thumbnailSize(for:)` when the cell's pixel bucket exceeds 1280. The phase
first measures on-disk growth on the seeded 20k library and reports it; the tier lands
only if the user has not said no to the number in the changelog's own words.

## P16 — browsing: video hover-preview, and playback on the canvas

*Effort M–L.*

- **Hover-preview:** `GifMotion`'s deferred v1.5 — a pooled `AVPlayer` (cap 1, the GIF
  coordinator's rule), dwell-gated, muted, looping, poster fallback, Reduce-Motion
  aware; the decision pure and tested like `shouldAnimateGif`.
- **Inline playback on the canvas:** `TileContent.video`; `SpaceContent` maps video
  assets; the engine hosts one `AVPlayerLayer` at a time on click; the LOD path draws
  the poster otherwise. Engine bookkeeping tested; playback itself is a manual pass,
  the repo's convention for media.

## P17 — the Safari Web Extension target

*013 · K2. Effort L. Needs a manual Safari pass by the user; the agent cannot verify
it.*

- A Safari Web Extension target in the Xcode project wrapping `extension/src/` — the
  single-capture surface only. Bulk sweeps and the MAIN-world hooks stay Chrome-only
  (013's scope line); a build step produces the Safari manifest without those content
  scripts. `browser.js` resolves `browser.*` (already written for this).
- `CaptureOrigins` gains `safari-web-extension` (3A made that one entry).
- Settings gains the "enable in Safari" guidance. The changelog names what the agent
  could not run: Safari's MV3 background lifetime, `scripting.executeScript`, and the
  App Store review consequence 013 records.

## P18 — P20 — the importers (gated)

*Run only once `resources/<eagle|raindrop|pinterest>/` holds an export the user
supplied. 12A's rule applies to each. Effort M each.*

- **P18 Eagle:** `EagleExportParser` → `[ImportPlan]` from a library's `metadata.json`
  and each `images/<id>.info/metadata.json` (folders, tags, url, annotation).
- **P19 Raindrop:** the CSV export (title, url, tags, folder, created) → link-card
  plans; media is fetched through the existing `PageResolver` / `RemoteImageFetcher`
  path in a second pass, with the auth-walled hosts refused as they are today.
- **P20 Pinterest data export:** the DSAR JSON (boards, pins, image URLs) → plans; the
  same fetch pass.
- Shared, built once in P18 and reused: a File ▸ Import ▸ … submenu; one
  `ImportPanel` generalised from `ArchiveFolderPanel.presentImport`; progress through
  `ImportProgressPill`; the replay through `LibraryImporter`. Each parser ships the
  three fixture kinds, a drift note (which fields the parser depends on), and a status
  line naming the export version it was verified against.

## Status

| Phase | State | Changelog |
|---|---|---|
| P0 | done | [463](../.change-log/463-the-packages-get-their-foundations.md) |
| 17A | done — the gate's two arms split | [464](../.change-log/464-the-gate-tells-its-two-arms-apart.md) |
| P0b | done — 20k warm 1,535 → 59 ms, cold 1,676 → 303 ms, 41 MB resident | [465](../.change-log/465-the-corpus-goes-resident.md) |
| P1 | done — 16A's reaper half reported, not built | [466](../.change-log/466-the-app-target-gets-its-foundations.md) |
| P2 | done — target, seeder, four identifiers, three flows, a 14th gate stage | [468](../.change-log/468-the-mac-gets-a-window-a-keystroke-and-an-order.md) |
| P2b | done — unplanned (20A); the two thumbnail suites stop asserting residency against `NSCache` | [469](../.change-log/469-the-cache-that-was-never-promised.md) |
| P2c | done — unplanned (21A); `DetailImageCache` takes the same seam, 10 assertions across 8 tests. Committed after 22A cleared the `App target (UI)` blocker, on the same gate run | [470](../.change-log/470-the-second-cache-takes-the-same-seam.md) |
| 22A | done — unplanned; the keychain read leaves the main actor (`@concurrent`, not merely `nonisolated`), and the UI suite stops starting an endpoint it never asserts | [471](../.change-log/471-the-token-leaves-the-main-actor-at-launch.md) |
| P3 | done — one read model, one write funnel, one coalescer; 071 · 0a closed its own gate negatively | [472](../.change-log/472-the-feed-gets-a-model-of-its-own.md) |
| P4 | done — a second read model mounted; 057's archive claim found FALSE and pinned; `App target (UI)` since blocked by 470's signing prompt (fails on `HEAD` too) | [473](../.change-log/473-the-saved-search-becomes-a-place.md) |
| P5 | done — its own surface, the shared ordering; a documented three-tier ranking, a per-library MRU, no verbs; the smoke flow is written but ungated (474) | [475](../.change-log/475-the-switcher-is-its-own-surface.md) |
| P6 | done — a second scene at floating level, ⇧⌘P, read-only `GridInteraction`, P5's ranking behind one filter; the drag-source rule moved to the read model. A space in the palette is the named follow-up | [476](../.change-log/476-the-palette-is-the-second-window.md) |
| P7 | done — rebased onto `395e471`; 5A closed; 457–460 → 463–466 | [467](../.change-log/467-four-builders-and-the-numbers-that-collided.md) |
| P8 | done — no code: audited and found already shipped 2026-08-10 (356–364); 080's and 078's status blocks corrected. `App target` red on all four gate runs, on a different timing flake each time, green in isolation | [479](../.change-log/479-the-phase-that-had-already-shipped.md) |
| P9 | not started | — |
| P10 | done — the query grew `colorMatch`, the bridge stopped pinning it, ⇧⌘C opens the picker; no wheel (085) | [478](../.change-log/478-the-colours-learn-to-say-and.md) |
| P11 | done — the quoted photo is excluded by a per-photo `statusId`; the signal had to be HARVESTED first, and the named fixture was the wrong artifact. Extension green (638, no drift). Its two red Swift stages were **disk pressure, not contention** — P10 found the data volume at 100 %, 798 MB free (478). The drift-check hole is still open | [477](../.change-log/477-the-anchor-says-whose-photo-it-is.md) |
| P12 | not started | — |
| P13 | not started | — |
| P14 | not started | — |
| P15 | not started | — |
| P16 | not started | — |
| P17 | not started | — |
| P18 | waits for `resources/eagle/` | — |
| P19 | waits for `resources/raindrop/` | — |
| P20 | waits for `resources/pinterest/` | — |

### The gate, as P0 found it — and what it is now

099 recorded above that "the local gate is green", verified with `verify.sh **fast**` —
which has eleven stages. **`full` has twelve.** The twelfth, `Extension`, runs
`npm run drift-check`, and that script ended in `process.exit(failed || stale ? 1 : 0)`:
one exit code for two unrelated things. `failed` is drift — a parser disagreeing with a
fixture, fixable by a commit, the reason the canary exists. `stale` is a calendar fact —
the Instagram fixture (14-day window) aged out on **2026-08-28**, before this branch was
cut, and only a fresh capture from a logged-in session clears it.

So the stage printed *"No drift — every check that COULD run satisfied its invariants"* and
exited 1 anyway, and had done since August. P0 stopped and reported rather than committing.

**Issue 17, decided by the user: split the signals (17A).** Drift is exit 1 and still
fatal; staleness is exit 2 and renders as a `⚠` stage. The opt-in is per stage — only
`Extension` takes it, so no other stage can have a real failure downgraded. The window is
still 14 days and the reminder still prints. [464](../.change-log/464-the-gate-tells-its-two-arms-apart.md)
carries it and states the cost plainly: the failure mode moved from "a gate nobody can
pass" to "a warning nobody reads", and only the second is survivable.

**The gate for every phase from here is `verify.sh full` at exit 0**, which now means
**thirteen** stages passed, possibly with warnings named in the summary. P1 added
`App target (Release)` (8A) and P2 added `App target (UI)` (10A), which made `full`
fourteen for four phases — and then **issue 23D took the UI stage back out**
([474](../.change-log/474-the-gate-stops-claiming-a-window.md)): the runner must sign
ad-hoc, so every rebuild is a binary macOS has never granted automation to, and a red
that no code change can clear is a red people learn to re-run past. So `fast` is eleven,
`full` is **thirteen**, and the smoke suite runs by hand with `./scripts/verify.sh ui`.
A phase still does not commit without the gate — and a phase that ADDS a smoke flow
(P5, P6) says in its changelog that the flow is written and not gated. *(Corrected in
099 · P5; 474 changed the gate and left this paragraph saying fourteen.)*

Two things this left for later. Re-capturing the Instagram fixture is still worth doing on
its own merits — the fixture is genuinely stale and live sweeps may genuinely be broken —
and only the user can. And forcing the drift arm to prove it still fails turned up a hole
in the Instagram check itself: a fixture with every `items` array emptied **passes**, since
the check reports counts as signals without asserting they are non-zero. The other checks
were not probed for the same hole. **P11 owns it** — it is the phase that owns `extension/`.
*(Still open: [477](../.change-log/477-the-anchor-says-whose-photo-it-is.md) took P11's TODO
only, and says why the two are separate pieces of work.)*

### 18A — the undo-window reaper is withdrawn

16A had two halves. The marker half shipped in P1 and did the work it was for: launch
no longer walks the whole blob directory, because `runOrphanBlobGC` runs only when
`snapshots/.gc-pending` says a recoverable delete happened.

The reaper half rested on four premises, three of them false and the fourth fatal:

- `DeletedAssetsBackup` does **not** hold `[BlobRef]`. It holds `[Asset]`, `[Source]`,
  `[CollectionItem]`, `[AssetTag]` and `[CoverRef]`. Deriving blob refs from the assets
  is not dedup-safe — two assets can share a blob — and the dedup-safe list that *does*
  exist is built and discarded inside `deleteAssetsRecoverable`, in Core.
- **`levelsOfUndo` is set nowhere in the tree.** Nothing is ever evicted, so an
  eviction-triggered reap never fires.
- `UndoManager` publishes no eviction hook, so building one means bounding undo depth —
  a user-visible change no decision in this plan covers.
- `applicationWillTerminate` is synchronous, so a dedup-safe reap there would block
  quit on a database read.

**Decision (the user, issue 18): drop it, and record why.** The marker already triggers
GC on the next launch after a delete, so deleted media is reclaimed — the reaper would
only have made it sooner. A bespoke eviction mechanism for that margin is the
over-engineering this plan's preferences rule out. The backlog line *"deferring the
reaper within the undo window is a named follow-up"* closes as **not viable as named**.

If it is ever wanted, the shape that would work is not the one 16A described: retain the
dedup-safe `BlobRef` list on the backup at `deleteAssetsRecoverable` time, and sweep
backups older than the undo window on a timer — no undo bound, no eviction hook.

## Risks, named

- **Two sessions, one branch.** The worktree keeps the checkouts apart; the rebase in
  P7 is where they meet. Changelog numbers will collide; the rule for that is written
  above.
- **pbxproj edits by an agent** (P2, P6, P17). `xcodebuild -list` after every write and
  a second `verify.sh` is the guard, and it has held across 448, 454 and 098's phases.
- **UI tests flake.** P2 is scoped to smoke; a flow that flakes twice is reported, not
  retried into green.
- **Measurement gates that say stop.** P0's semantic row, P3's decode split, P15's
  size-on-disk: each may end its phase early. That is the phase working as designed.
- **What an agent cannot run.** Safari (P17), media playback (P16), and any real export
  (P18–P20) end with a named manual pass, in the changelog, for the user.
