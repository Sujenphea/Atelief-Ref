# 460 — the app target gets its foundations

[099 · P1](../.docs/099-mac-backlog-plan.md#p1--app-target-foundations) — the app
half of what [457](457-the-packages-get-their-foundations.md) built in the packages.
Seven items, `AtelierRefs/` plus the two package files the items themselves name and
`scripts/verify.sh`. None of 098 · P4's four files were touched.

Three of the seven landed as written. Two landed and found something the plan did not
know. **One of them cannot be built as described, and the report on why is the
substance of this entry.**

## 8A — the debug surface stops shipping, and the gate learns to notice

`AtelierRefs/AtelierRefs/Debug/` is 2,765 lines across seven files: a grid bake-off
with three competing implementations, a pinch bake-off, a frame-time recorder, an
autorun harness and a scroll driver. Six of the seven had no `#if DEBUG` anywhere in
them, and `AtelierRefsApp.swift:19` read

```swift
@NSApplicationDelegateAdaptor(GridBakeoffAppDelegate.self) private var bakeoffDelegate
```

— in every build. The app the user installs carried the whole harness and installed
its delegate at launch, because an app gets exactly one `NSApplicationDelegate` seat
and the spike had taken it for want of anywhere else to put the adaptor.

The seat now belongs to a five-line production `AppDelegate` that forwards to the
bake-off **only in DEBUG**, where `Debug/` exists to be forwarded to. That is not a
comment promising the harness is gone; in a Release build `GridBakeoffAppDelegate` is
not a name that resolves, so the compiler is what checks it.

`CanvasRenderer/Sources/CanvasRenderer/Spike/` went behind the same guard. The plan
said its only non-spike reference was a doc comment; that is confirmed — the four
types are used by `CanvasBenchmark`, `CanvasPinchTests` and `SpikeDataTests`, all of
which build in debug, and by nothing else in any module. (`AtelierIngestionTests` has
a `FixtureImages` of its own; the names collide and the types do not.)

### `-library-root` and `ATELIER_LIBRARY_ROOT` are not the same kind of thing

`LibraryLocation.overrideValue` honoured both unconditionally, and they are not
equally reachable. A launch argument arrives from a double-click: Finder's Open-with,
a `.command` file, a login item, `open -a … --args` from any script. In a shipped
build that is not a debugging affordance, it is a way for the app to open a library
the user did not choose. The argument arm is now `#if DEBUG`; in a Release build
`arguments` is not consulted at all, so a passed `-library-root` is not ignored after
parsing, it is never parsed.

`ATELIER_LIBRARY_ROOT` stays unconditional in every configuration, and the reason is
written where the next person will look: an environment variable needs a shell, a test
runner or a scheme to put it in the process environment, which is exactly the audience
the hatch is for — and **P2's UI-test target seeds its throwaway library through it**.

### The gate gains a Release build, and this is why it had to

Every stage `verify.sh` ran was a debug build. `swift test` is debug; the app stage is
debug. So the Release side of every `#if DEBUG` in the repo was **unparsed** — a type
referenced from production code but declared inside a guard compiles green all day and
fails at the one build that ships. Adding three dozen guards without adding that stage
would have been adding an untested claim.

`App target (Release)` is a plain `run_stage`, not the `run_warnable_stage`
[458](458-the-gate-tells-its-two-arms-apart.md) added: a Release build failure is a
real failure, and the warn opt-in stays the Extension stage's alone. Build only, never
test — the test targets are debug-configured and there is nothing to run; what is
checked is that the app's sources still form a program without `DEBUG`. It is a
full-mode stage, because `fast` is meant to stay in the seconds and a second whole-app
compile is not that. `ci.yml` was left alone (9C).

## 2A — the export bridge is filled, and both bridges are made to agree

457 closed by saying so plainly: `AtelierExport.TextStyle` had gained
`fontFamily` / `weight` / `alignment`, `MoodboardRenderer` honoured them, and **no
bridge filled them**, so every export was still Helvetica regular flush left and
byte-identical to before the renderer changed. This phase filled
`MoodboardExport.textStyle(from:)`, then wrote the test that makes the fill provable.

`StyleBridgeConformanceTests` drives one fixture set of `ElementStyle`s through BOTH
`ElementRendering.textStyle(for:)` (the board) and `MoodboardExport.textStyle(from:)`
(the page) and compares field for field. The fixtures cover a bare style, a nil family,
an empty family, every `TextWeight` and `TextAlign` token **taken from the enums
themselves** (so a token added later joins the suite with no edit), an unknown token in
both enum fields, the legacy 062 `resizeMode`, the 063 `textAutoWidth` flag, and three
colour forms including a malformed one.

**It was proven to fail before the fill.** Reverting `textStyle(from:)` to its
three-field shape produced **44 failing test cases** across `textStylesAgree`,
`frameLabelsAgree`, `defaultsAreOneSource`, `aNilStyleMatchesABareStyle`,
`unknownTokensDegradeTogether` and both token-parity tests. The bridge was restored
and the suite is green.

### Writing the test found a third disagreement, and a fourth waiting to happen

**The default `fontSize` was 16 on the board and 17 in the export.** An element with
no stored size drew a point larger on the page than on the screen, and had since the
export shipped. `MoodboardExport`'s defaults are now expressed in terms of
`ElementRendering`'s rather than restated — one source, the way `defaultTextColorHex`
already was — and `defaultsAreOneSource` pins it.

**And filling the text bridge would have opened a new gap in the frame bridge.**
`FrameStyle.label` is a `TextStyle`, so the export's frame captions inherit family,
weight and alignment for free the moment `textStyle(from:)` carries them — while the
BOARD's frame label was built by hand from three fields and would not have. So the
board's label now routes through `ElementRendering.textStyle(for:)` too, and
`frameLabelsAgree` drives the whole fixture set through both frame bridges as well.
Closing one divergence by opening another is the exact failure this suite exists to
prevent, and it would have shipped in the same commit.

### A fourth hex parser joins the grammar suite

`HexGrammarTests` pinned three parsers to one grammar.
`AtelierIngestion.ColorPalette.rgb(fromHex:)` is a fourth reader of the same stored
strings and no cross-parser test could see it — it was `internal`. It is `public` now
and in the suite.

It takes **six digits only**, on purpose: it reads what `ColorSwatch.encodeList`
writes and never a colour a person typed. `theFourthParserIsSixDigitsOnly` asserts the
narrowness itself, with the premise (`RGBA` DOES take `#f80`) asserted alongside it, so
neither widening nor narrowing can happen quietly.

**It was already divergent, in the one way nothing was looking.** It trimmed
`.whitespaces` where the other three trim `.whitespacesAndNewlines`, so a stored value
with a trailing newline was a colour on three surfaces and "not a colour" on the
fourth. Found by adding it to the suite's existing `whitespace` case; fixed in one
word.

## 4A — the SearchRules ↔ LibrarySearchQuery bridge

`SearchRules(query:)` and `LibrarySearchQuery(rules:)`, in one file with the reasons
in its header. Nothing in the app calls them yet — P4 is what will — so what this
phase ships is the mapping and the canary over it.

The canary is the point. `SearchRules`' own header records what happened without one:
`favoritesOnly` was added to `searchAssets` in 011, the rules blob never carried it,
and every saved search silently dropped the favorites filter. Nothing threw and no test
failed.

`exhaustiveness` takes a `Mirror` over BOTH sides and asserts every stored property is
either mapped by the bridge or named in an allowlist with a reason. **It was proven to
fail**: a dummy `Bool` added to `LibrarySearchQuery` made it fail, naming the field and
saying which of the two lists it has to join. The probe was removed and
`git diff` on `LibrarySearch.swift` is empty.

Four things do not cross, and each is asserted rather than assumed:

- **`tagNameContains`** — the live `tag:` needle, an input method that resolves to a
  tag token before anything is persisted.
- **plural `collectionIDs`** — 015's single-collection rule. Asserted from BOTH ends:
  `pluralScopeCollapses` shows the collapse, and `rulesHaveNoPluralScope` reflects over
  `SearchRules` to show the storage shape is what forces it. `AppServices.evaluate`
  re-expands the single id as `[collectionID]`, so the loss is at the storage shape and
  not in this file.
- **`sort`** — the grid's display mode. The rebuilt query reconstructs `.newest`, NOT
  `.relevance`-when-there-is-text, because `evaluate(rules:)` passes no sort at all and
  `searchAssets` defaults to `.newest`. Guessing the live field's rule would make a
  reconstructed query order differently from the service that owns the rule.
- **`platform`** — the reverse gap, and the plan does not mention it: `SearchRules` can
  carry a platform and the live search field has no chip for one. A stored rule keeps
  it and evaluates with it; only the reconstructed query is without it.
  `platformIsRuleOnly` says so, and warns that re-saving from the live field would drop
  it.

`roundTripThroughTheBlob` runs the round trip through `encoded()` / `decoded(fromJSON:)`
rather than in memory only, because a field written to a struct the codec has no key
for would pass an in-memory round trip and vanish on the first relaunch — which is,
precisely, the 011 incident.

## 6A (app) — five tables became one, and a `default:` that shipped a debug description

`AtelierError` has been `LocalizedError` with an exhaustive, `default`-less table since
P0. This is the app side.

**The plan says five `message(for:)` switches; there are four that switch on
`AtelierError`** — `IngestionModel`, `SpaceModel`, `ImportReplay` and the mobile
`LibraryStore`. The other `message(for:)` functions in the controllers
(`BackupTarget`, `ArchiveExportController`, `ArchiveImportController`) map different
error types entirely — `FolderAccessError`, `BackupRunner.RunError`,
`ArchiveReadError` — and have nothing to collapse into. The count is prose, not a
decision; the decision is unaffected. Three of the four were collapsed.

The arm that mattered most is the one nobody wrote on purpose.
`IngestionModel.message(for:)` ended `default: return "\(error)"`, so a case nobody had
thought about reached the user as `persistenceFailure(detail: Optional("SQLite 11:
database disk image is malformed"))` — an enum's debug description, in an alert.
`SpaceModel` had the same arm. `noDebugDescriptionsLeak` is the standing assertion
that neither can come back.

**Two overrides survive, and both were made honest.** They are the phrasings Core
cannot write — "That folder no longer exists." and "That space no longer exists." are
about a thing deleted out from under an open window, where Core's "Couldn't find that
folder." reports a lookup that missed. But each used to answer for EVERY `.notFound`
its surface could produce, so a missing asset on a board was reported as "that space no
longer exists": the model naming the wrong thing, confidently. Each is now scoped to
its entity, and `ingestionOverrideIsScoped` / `spaceOverrideIsScoped` assert that a
`.notFound` on anything else falls through to Core's noun table — which is the only
place that can turn `"collection_item"` into a word a person has seen.

**One thing left the alert.** `persistenceFailure`'s SQLite detail was appended to the
message by both surfaces; AtelierCore keeps it out of its sentence on purpose (P0: "the
diagnostic belongs in a log, not in an alert"). It now goes to `AppLog.model` from one
place. That is a change to what the user reads, and it is recorded here as one:
`persistenceDetailIsNotShown` pins it, and it is easy to reverse if the call was wrong.

`ImportReplay.message(for:)` was left alone. Its doc comment says it is "not user
prose — for the report and the log", and it renders into `ImportFailure` records that
no surface currently displays. Turning a deliberate diagnostic into prose is not what
6A asked for.

### The sixteen silent `try?`s, and what each one says now

Four in `IngestionModel` (found exactly at the plan's `:805`, `:810`, `:3345`, `:3387`
— P0 and P0b touched no app file, so the line numbers had not moved) and twelve in
`SnapshotManager`. Every one stays best-effort; none of them can fail a launch, a
delete or a restore. What changed is that the failure is no longer invisible.

`SnapshotManager` gained one helper for eleven of its twelve, so the sentence is
written once: `attempt(_:_:)` runs the work, returns `nil` on a throw, and logs
`snapshots: <what> failed: <error>`.

| site | what it now says |
|---|---|
| `IngestionModel:805` | `launch: pausing stale open jobs failed — a sweep may still show as running` |
| `IngestionModel:810` | `launch: known-item reconcile failed — a re-sweep may skip a source whose bytes are gone` |
| `IngestionModel:3345` | `seeding a space from a collection: setting its cover failed` |
| `IngestionModel:3387` | `adding to a space: seeding its first cover failed` |
| `SnapshotManager:85` (`contentsOfDirectory`) | `snapshots: listing snapshots/ failed` — and a directory that does not exist yet is no longer treated as a failure at all, because that is an ordinary first launch |
| `SnapshotManager:124` (daily snapshot) | `snapshots: the daily snapshot failed — this library has no fresh recovery point` |
| `SnapshotManager:147` (pre-migration marker) | `clearing the pre-migration-failure marker` — a removal that fails turns a one-time warning into a permanent one |
| `SnapshotManager:178` (`isHealthy`) | `integrity-checking <snapshot>` — the sheet still gets one typed refusal; the reason the file would not open is now somewhere |
| `SnapshotManager:206` (read `.pending-restore`) | `reading the pending-restore marker` — guarded by `fileExists` first, so "no marker" stays the silent ordinary case and only an unreadable one is logged |
| `SnapshotManager:207` (clear it) | `clearing the pending-restore marker` — a marker that survives runs the restore AGAIN next launch, over a library already restored |
| `SnapshotManager:211` (`isHealthy`, staged) | `integrity-checking the staged snapshot <name>` |
| `SnapshotManager:228` (write `.just-restored`) | `writing the just-restored marker` — if this fails the next launch runs the orphan GC instead of the reconcile, and reaps the media the reconcile exists to protect |
| `SnapshotManager:235` (rollback) | `rolling the live database back after a failed restore`, and if THAT fails, an `AppLog.model.fault` naming where the library actually is — this is the one path that can leave the app with no database where its database used to be |
| `SnapshotManager:277` (read `.pending-library-id`) | `reading the pending-library-id marker`, same `fileExists` guard |
| `SnapshotManager:278` (clear it) | `clearing the pending-library-id marker` — a survivor fires after some unrelated future restore and adopts an identity nobody asked for |
| `SnapshotManager:299` (clear `.just-restored`) | `clearing the just-restored marker` — a survivor pins the library on the post-restore path forever |

The `applyPendingRestore` catch also gained a line for the install failure itself,
which previously returned `false` in silence.

## 11A — tests await signals, not clocks

`DetailImageLoader`, `ThumbnailPipeline` and `LibrarySearchModel` each gained an
`EventSignal<Event>`: a small fan-out broadcast of lifecycle events, unlistened-to in
the app (an `emit` takes a lock, finds no continuations and returns).

What is emitted is deliberately the lifecycle, not the answer. A test that awaits the
answer proves nothing about coalescing; a test that awaits *"twenty-four requests have
attached to one task"* proves the thing it is named after, and takes exactly as long as
that takes.

| test | was | is |
|---|---|---|
| `DetailImageLoaderTests:249` | sleep 80 ms, then release the blocked decode | await 1 `started` + 23 `joined` |
| `DetailImageLoaderTests:277` | sleep 50 ms | await `joined` |
| `DetailImageLoaderTests:312` | sleep 50 ms, "let the promotion land" | await `promoted` |
| `ThumbnailPipelineTests:328` | sleep 80 ms | await 1 `startedDecoding` + 31 `joined` |
| `ThumbnailPipelineTests:537` | a 500-iteration inline poll of the decode probe's call count | await `startedDecoding` |
| `ThumbnailPipelineTests:549` | a 200-iteration inline poll of `cancellablePrefetchKeys` | await `promoted` |
| `LibrarySearchModelTests:207` | sleep 120 ms, "let any stragglers land" | await three terminal events, and assert two are `superseded` |

That last one is the clearest gain. A query cancelled by a newer keystroke returned
without touching any published state, so there was **no evidence at all** that a
superseded query had finished being superseded — the 120 ms was the only thing standing
between "only the latest ran" and a race. The model now emits `superseded` at each of
those four early returns, and the test asserts *two of three tasks were cancelled and
one settled*, which is a strictly stronger statement than the sleep could make.

`poll` moved to `AtelierRefsTests/TestSupport/Poll.swift`, and the two inline copies in
`ThumbnailPipelineTests` are gone. **Fifteen other private copies were left alone** —
`settle` ×8, `waitUntil` ×5, `eventually` ×2, under six different iteration counts.
They are correct, they are not what 11A is about, and a sixteen-file rename would have
buried this phase's real changes in a diff nobody could read. Where the next one should
go is now written down.

`ShelfControllerTests:221-226` keeps its delays, as instructed: the delay there is the
scenario.

`BoundedWorkTests:131` — which is in **AtelierIngestion's** package suite, not the app
target — lost its 50 ms drain wait outright rather than gaining a signal. The wait
existed only because the progress callback handed each report to a detached `Task`; a
lock-guarded recorder writes inside the callback instead, so when `runBounded` returns
every report has already landed. That is not a faster wait, it is the absence of one.

`DetailImageLoaderCoreTests` and `LibrarySearchModelTests` gained the `.timeLimit`
trait `ThumbnailPipelineTests` has carried since 330. Awaiting a signal is exact, and
an exact wait for something that never happens is a hang rather than a wrong answer.

`ThumbnailWindowPrefetcherTests` needed nothing: it has no sleeps at all and was
already fully signal-driven through `waitForPendingWork()`. The flake P0b saw was in
`ThumbnailPipelineTests`' three sleeping cases, and those are the ones above.

## 16A — the launch sweep runs on a marker, and the reaper cannot be built

The launch orphan-blob GC enumerates every file under `blobs/` and diffs it against the
hashes the database still references. It exists because a recoverable delete
deliberately does not reap — an in-session ⌘Z has to find the bytes on disk — so a
delete that was never undone leaves orphans.

It ran on **every launch**, whether or not anything had ever been deleted: a full
directory walk of the library, at launch, almost always to discover there is nothing to
do, and growing with the library rather than with the deleting.

A recoverable delete now writes `snapshots/.gc-pending`, and the launch decision is a
pure three-way function — `reconcile` after a restore, `sweep` on a marker, `none`
otherwise — with the restore winning, because sweeping over a restored (older)
database trashes the media the reconcile exists to protect. The marker is cleared only
by a sweep that **completed**: a sweep that refused to run because it could not read
the referenced set leaves it, or the orphans it declined to look at go invisible until
the next delete happens to set it again. The redo of a delete marks too, because it
orphans exactly as the original did. `runPostRestoreBlobReconcile` keeps its full walk,
untouched.

### The undo-window reaper is NOT built, and here is why

The plan asks: *"when the undo stack evicts a `DeletedAssetsBackup` (or at
`applicationWillTerminate`), the `BlobRef`s it holds are reaped by list — no
enumeration."* Read against the code, three of that sentence's premises are false, and
the fourth makes it unimplementable as stated:

1. **`DeletedAssetsBackup` holds no `BlobRef`s.** It holds `[Asset]`, `[Source]`,
   `[CollectionItem]`, `[AssetTag]` and `[CoverRef]`. Refs can be derived from
   `asset.blobHash` + `asset.mimeType`, but that derivation is **not dedup-safe**: a
   content-identical asset that survives shares the hash, and reaping it would delete a
   living asset's bytes. The dedup-safe list exists exactly once, transiently, as
   `performDelete`'s return value inside `deleteAssetsRecoverable` — where it is
   discarded with `_ =`. Capturing it means changing AtelierCore's public return type,
   which is P0's package and not P1's.
2. **The undo stack has no eviction.** `levelsOfUndo` is never set anywhere in the
   repo, so `UndoManager`'s default of *unlimited* applies and nothing is ever dropped.
   "When the undo stack evicts" names a mechanism that does not exist.
3. **`UndoManager` publishes no eviction hook.** Setting `levelsOfUndo` discards the
   oldest groups silently; there is no delegate or notification. Building one means a
   parallel deque inside `UndoStack` **and bounding undo depth**, which is a
   user-visible behaviour change no decision in 099 covers. (It is also subtle: the
   ping-pong at `UndoStack.installUndo` re-registers a logical action on every
   undo/redo, so a naive registration count would evict the wrong entry.)
4. **`applicationWillTerminate` cannot do this work.** It is synchronous and the
   process exits immediately after. A dedup-safe reap needs an `async`
   `referencedBlobHashes()` read before it trashes anything, and the only way to run
   that there is to block the quit on a database read.

So the marker half of 16A shipped and the reaper half did not. The marker half is the
half that removes the per-launch cost; the reaper would only have moved a bounded
amount of reclamation earlier than the next launch. **This needs a decision, and it is
not one an agent should make.**

## The noted items

**`CaptureTokenStore` takes `service:` — and `defaults:`.** It had no tests, and the
reason it had none is the reason it needed the parameter: every entry point was
hard-coded to the production Keychain item, so any test would have read, overwritten
and deleted the developer's REAL capture token — silently unpairing their browser
extension — and left an `AtelierCaptureToken` key in their standard defaults. The
`defaults:` parameter is beyond what the plan named and is the same argument: the
legacy-migration path is untestable without it. A `delete(service:)` exists for
teardown and says in its own doc comment that it is not a product affordance. Nine
tests, all against per-test UUID-named services and suites, and one of them asserts the
production service string is unchanged — making a name a parameter must not change the
name.

**`CollectionDestinationList` and `DestinationPicker` take the memo.** The list rebuilt
the whole hierarchy — group by parent, sort each parent's children, recurse, flatten —
on every body pass, and TWICE per pass, because `nodes` was a computed property read
once for `isEmpty` and again for the `ForEach`. Inside `DestinationPicker` that is
three rebuilds **per arrow key**, since the cursor is `@State` on the picker.
`MoveTargetsCache` is the memo `CollectionView` and `LibrarySearch` have used for their
context menus since 012; `SpaceView` and `ItemDetailView` gained one, `nodes` is read
once per pass, and `pickerCursorDoesNotRebuild` walks a cursor sixty rows and asserts
`buildCount == 1`. The pure statics keep their signatures, because
`MoveAddShortcutTests` drives them directly, and `cachedRowsMatchTheStatic` asserts the
two paths are one answer.

**`applyOrder`'s membership pre-read is gone.** It read the WHOLE collection — every
membership row joined to its asset and source, decoded in full — in front of every
drag, purely to strip ids that were no longer members. P0's `setGridOrder` ignores
non-members by contract (`WHERE collection_id = ? AND asset_id IN (…)` simply matches
no row), which is what the pre-read was computing, and it computes it inside the
statement that was going to run anyway. The contract was read in P0's code before the
deletion, and `reorderSurvivesAStaleID` covers the case the pre-read was paying for:
an asset deleted in another window, still in this window's `items`, named in the drag —
the survivors are ordered and nothing surfaces as an error. Nothing tested that before.

## The gate found a flake nobody had seen, and it was not this phase's

The first `verify.sh full` of this phase came back `✗ AtelierIngestion`, on
`ColorExtractorTests` · *"randomized palettes satisfy the invariants (…, deterministic)"*.
The two arrays it printed had identical hexes and identical coverages; **two entries
with EQUAL coverage were transposed**.

`ColorExtractor.finalize` sorted `{ $0.coverage > $1.coverage }`. That is not a total
order — two equal coverages compare equal in both directions — and `sort` is not stable,
so the tied pair fell back on the order `histogram` produced, which is
`Dictionary.values`, whose iteration order Swift randomizes **per process** from the
seeded hasher. `swift test --parallel` runs several processes.

So the assertion held on the author's machine, held in every filtered run, held 12 times
out of 12 when re-run alone at HEAD, and lost a coin flip somewhere in a full parallel
run. That is the worst shape a gate failure can have, and with six phases left to run
behind this gate it would have been attributed to whatever phase happened to hit it.

Two lines fix it, and they are the lesson the neighbouring file had already learned —
`ColorPalette.merged` breaks its ties on the bucket's raw value and its comment says
*"so the order is total rather than whatever the dictionary iterated"*:

- `finalize` breaks equal coverage on `hex`;
- `histogram` returns its buckets sorted by quantized key rather than in `Dictionary`
  order, so the per-process seed cannot reach k-means' seeding either.

**This is outside P1's items and is declared as such.** It was fixed rather than
reported-and-left because rule 1 requires the gate at exit 0 and the alternative was
re-running until it passed, which is how a flaky gate becomes a gate nobody reads (458,
in its own words). Two tests pin it: one constructs three colours with exactly equal
counts given in descending hex order, so a stable sort of the input would give the wrong
answer and only a real tie-break gives the right one; the other feeds the same pixels in
five different insertion orders. The suite was then run **8 times in full, in parallel,
with zero failures**.

## Verification

`./scripts/verify.sh` (full):

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target
  ✓ App target (Release)
  ⚠ Extension

All 13 stages passed, 1 with a warning above.
```

Exit 0. **Thirteen stages, not twelve** — `App target (Release)` is this phase's, and it
is the one that compiles the other side of every `#if DEBUG` the phase added. `App
target` at TEST SUCCEEDED over the whole app suite. `⚠ Extension` is the stale Instagram
fixture 458 split out; it is not this phase's, and no code here touches `extension/`.

The run above is the SECOND. The first is written up under "the gate found a flake"
above: `✗ AtelierIngestion`, on a nondeterminism older than this branch.

## Tests added

**66 new `@Test`s in the app suite** (1,633 → 1,699 declarations; more cases than that,
several being parameterized), **2 in `AtelierLibraryPathsTests`**, **2 in
`AtelierIngestionTests`**. No test was deleted and none was weakened; one
(`BoundedWorkTests.progressIsMonotonic`) lost a sleep and kept every assertion.

**4A — `SearchRulesBridgeTests` (13)** · a fully-populated query survives query → rules
→ query; the rule the round trip goes through carries every dimension; the round trip
survives the STORED form, not just the in-memory one; an empty query and an empty rule
are each other's image; blank-but-not-empty text normalizes to no text filter; the
`tag:` needle is an input method, and does not persist; a saved search is
single-collection: the plural scope collapses to the first; SearchRules has no plural
collection scope to save into; sort is the grid's display mode, not part of the rule
(×2 sorts); a rule's platform survives storage but cannot reach the live query; tags AND
and colors OR, matching the field and `searchAssets`' defaults; a rule written with the
other match modes still rebuilds a runnable query; **every stored property of both sides
is mapped or explicitly allowlisted**.

**2A — `StyleBridgeConformanceTests` (8)** · both bridges read one `ElementStyle` the
same way (×20 fixtures); a frame's LABEL crosses both bridges identically too (×20); a
frame with no text has no label on EITHER side; a nil style is the same element as a
bare style, on both sides; the two bridges default an unstyled element to the same size
and colour; the weight and alignment tokens are rawValue-identical across three modules;
every alignment token crosses to both renderers; an unknown token degrades to the SAME
default on both sides.

**2A — `HexGrammarTests` (1 new, 6 extended)** · the colour-bucket parser takes SIX
digits only, and says so (×3). The six-digit agreement cases and the rejection matrix
now drive `ColorPalette.rgb(fromHex:)` alongside the other three parsers.

**6A — `ErrorMessageTests` (10)** · anything that is not an `AtelierError` keeps its own
sentence; an `AtelierError` answers with Core's sentence, not a restatement;
`persistenceFailure`'s SQLite detail does not reach the alert; no sentence anywhere is
an enum's debug description; `IngestionModel` says "that folder no longer exists" for a
missing collection; …and NOT for a missing anything else; `SpaceModel` says "that space
no longer exists" for a missing space; …and NOT for an asset or an element that has gone
from the board; the two surfaces disagree only where they mean to;
`notFound(_:entity:say:)` matches only its own entity, and only `notFound`.

**8A — `LibraryLocationTests` (2)** · the `-library-root` ARGUMENT is read in DEBUG
builds only; `ATELIER_LIBRARY_ROOT` is read in EVERY configuration.

**11A — `EventSignalTests` + `PollTests` (10)** · with nobody listening, emitting is a
no-op that costs a lock; a stream receives what is emitted after it was made; two
listeners each get every event; a wait whose condition is ALREADY true returns
immediately; a wait for a count resumes exactly when the count is reached; a recorder
that goes away unsubscribes, and emitting afterwards is safe; events arrive in the order
they were emitted; `poll` returns true immediately when the condition already holds;
returns false after the timeout when it never holds; settles as soon as the condition
becomes true.

**16A — `BlobSweepMarkerTests` (11)** · a restore always wins — a sweep would trash media
the reconcile protects; with a marker and no restore, the launch sweeps; with neither,
the launch does nothing at all; the marker is absent until something writes it, and
idempotent after; the marker creates the snapshots directory if the library has none
yet; the marker is not mistaken for a snapshot by the snapshots list; a recoverable
delete marks the library for a sweep; a REDO of a delete marks too; a model with no
snapshots directory marks nothing and still deletes; a completed sweep reclaims the
orphan and clears the marker; a sweep with nothing to reclaim still clears the marker.

**Noted — `CaptureTokenStoreTests` (9)** · an empty store loads nothing; a saved token
loads back verbatim; saving twice replaces rather than duplicating; a legacy
`UserDefaults` token migrates once, then the plist copy is gone; the Keychain wins over
a stale legacy value; an empty legacy value is not a token; two services do not see each
other's token; delete removes the item and is idempotent; the production service name is
the one the app has always used.

**Noted — `CollectionDestinationPerfTests` (3)** · the memoized rows are the same rows
the pure static builds; exclusion behaves identically on both paths, including an
excluded parent; a picker's arrow keys stop rebuilding the tree.

**14A — `AppUndoTests` (1)** · a reorder naming an asset deleted in another window still
orders the rest.

**Out of scope, forced by the gate — `ColorExtractorTests` (2)** · equal coverages break
on hex — the order is TOTAL, not merely sorted; the swatch order does not depend on the
hasher's per-process seed.

## What is still NOT covered

**The undo-window reaper.** Named above at length. The launch sweep no longer runs for
nothing, which is the cost this item was mostly about, but blobs from a delete that is
never undone still wait for the next launch rather than being reclaimed when the undo
that protected them goes away. Four things have to be decided before it can be built,
and two of them (bounding the undo stack; changing `deleteAssetsRecoverable`'s return
type) are outside this phase's package scope.

**"GC skipped without the marker" is asserted on the pure function, not on a launch.**
`launchBlobPass` is exhaustively tested, and the delete → marker → sweep → clear chain
is tested end to end against a real `AppServices` and `MediaStore`. What is NOT tested
is `bootstrap()` itself — it opens a library from `LibraryLocation.resolvedRoot()`, and
no test in this suite runs it. The wiring between the pure decision and the two calls
it guards is read, not proven.

**The "sweep refused to run" path is unproven.** `sweepOrphanBlobs` keeps the marker
when `referencedBlobHashes()` throws, which is the branch that matters most for not
losing orphans — and there is no seam to make that read fail, so no test drives it.

**Nothing in 4A has a caller.** Both initialisers are dead code until P4 adds "Save
this search…" and the smart-collection sidebar. The round trip is proven against the
stored blob; what is not proven is that the query the search field actually builds is
the query a saved search should hold, because no UI hands one over yet.

**`AssetTagsStoreSuggestionsTests:116` still sleeps 60 ms.** It is a negative
assertion — "accept on a tag the user already owns changes nothing" — so under load it
fails safe rather than flaking: a slow machine makes it pass when it should fail. That
is a weakened assertion, not a flaky one, and fixing it means a settle signal on
`AssetTagsStore` that nothing else needs yet.

**The `#if DEBUG` guards are compile-checked, not behaviour-checked.** The Release
stage proves the app builds without `DEBUG`; nothing proves the bake-off window cannot
be opened in a Release build, or that `-library-root` is refused there, because the
suite only ever runs in debug. `argumentArmIsDebugOnly` writes the Release half of the
contract down and asserts it in whichever configuration it is compiled for; the
Release build stage is what makes that more than a comment.

**The `persistenceFailure` detail leaving the alert is a judgement call.** The phase
brief says not to delete an override that changes what the user reads; 6A's Core half
says the diagnostic belongs in a log. Both were followed where they agreed and the
Core decision was followed where they did not. It is one line to reverse in
`ErrorMessage.text(for:)` and a test names it.

**`ImportReplay.message(for:)` was not collapsed**, deliberately — see above. If the
import report ever gets a surface, its messages should be revisited as prose.

**The 8A guards changed no test count and no behaviour anyone can see.** 2,765 lines
left the Release binary; nothing measured the binary before or after, so "the debug
surface stops shipping" is a fact about the source, not a number.
