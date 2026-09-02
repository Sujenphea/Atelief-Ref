# 457 — the packages get their foundations

[099 · P0](../.docs/099-mac-backlog-plan.md#p0--package-foundations) — the first phase of
the Mac backlog, on `feat/mac-backlog` in its own worktree. Six behavioural items across
Core, Server, Export and Archive, then a pure file split. No file under `AtelierRefs/` was
touched; that is P1's.

Two of the six were measurement gates. **One of them says build the next phase, and one of
them says the thing it measured was 98× slower than anyone had checked.**

## The two numbers

### 15A — semantic search is 1.5 seconds at 20,000 items

`ScaleHarnessTests` gained a `semanticSearchAssets` row: one deterministic, L2-normalized
512-float embedding per asset, then a query timed cold, warm, and scoped to a collection.

| N | seed embeddings | cold | warm | scoped |
|---|---|---|---|---|
| 300 | 194 ms | 26.8 ms | 25.8 ms | 25.8 ms |
| 1,000 | 624 ms | 81.8 ms | 79.4 ms | 79.5 ms |
| 5,000 | 3,087 ms | 386 ms | 388 ms | 393 ms |
| 10,000 | 5,645 ms | 753 ms | 750 ms | 759 ms |
| **20,000** | 12,291 ms | **1,638 ms** | **1,547 ms** | **1,570 ms** |

Dead linear, ~77 µs per vector, and the three columns are the same number: there is no
cache to be warm, and the structured scope narrows the SQL without narrowing the work,
because in this harness every asset is in the collection anyway.

**The threshold the plan set was ~100 ms at 20,000. It is 1,547 ms — fifteen times over,
and it crosses 100 ms at about N = 1,300.** So **P0b is scheduled**: the resident corpus
cache 099 describes, keyed by `modelVersion`, invalidated from the two write sites, scored
with Accelerate and topped-k by partial selection rather than a full sort. The cost the
plan asks to be stated: 2 KB × N resident, so 40 MB at 20,000.

Worth naming for whoever builds it, because the shape of the curve says where the time is
NOT: the query is linear with no visible fixed cost above ~26 ms, so the full sort
(`n log n` over 20,000, then `prefix(50)`) is not the dominant term. Decode and dot-product
per vector is. A cache that removes the per-query BLOB decode is therefore the right first
move, and the partial selection is the smaller half of the win.

### 14A — the grid reorder was 52 seconds

`setGridOrder` looped `orderedAssetIDs` doing one SELECT and one UPDATE per row. Reversing
a 20,000-item collection — what a "sort by hand" drag can produce in one gesture:

| N | before (per-row loop) | after (chunked `CASE`) |
|---|---|---|
| 300 | 79.7 ms | 3.2 ms |
| 1,000 | — | 12.4 ms |
| 5,000 | — | 74.7 ms |
| 10,000 | — | 194 ms |
| **20,000** | **51,750 ms** | **525 ms** |

98× at 20,000, 25× at 300. The intermediate Ns have no "before" because the two runs that
have one bracket the range and the shape is not in question — it was 2.6 ms per row, and it
is now 26 µs.

## 14A — and the behaviour change that came with it

One chunked statement per 500 ids:

```sql
UPDATE collection_item
   SET manual_order = CASE asset_id WHEN ? THEN ? … END
 WHERE collection_id = ? AND asset_id IN (?, …)
```

Three bound variables per id (`WHEN ? THEN ?`, plus its slot in the `IN`), so 500 ids bind
1,501 — the chunk exists for `SQLITE_MAX_VARIABLE_NUMBER`, and the test that spans the seam
says so where a reader will find it.

**Ids that are not members are now IGNORED rather than throwing `.notFound` and rolling the
batch back.** That is the point of the change as much as the speed is: every caller was
pre-reading the whole membership set to strip exactly those ids before calling —
`IngestionModel.applyOrder` does a full `collectionItems` read in front of every drag — and
that pre-read was computing what the statement now does for free. P1 removes it.

Three details that are behaviour, and are tested:

- **The `IN (…)` is load-bearing.** Without it, every other membership in the collection
  matches the UPDATE and takes the `CASE`'s implicit `ELSE NULL`, silently dropping every
  unlisted item to the front of the grid.
- **Positions are list indices, so ignoring a non-member leaves a gap.** `[gone, a, b]`
  gives `a` 1 and `b` 2. Only the relative order is meaningful, and compacting would move
  rows the caller never mentioned.
- **A duplicated id takes its LAST index**, which is what the loop did.
  `ImportReplay.swift:115` already documents that rule as the reason it deduplicates.

The `.notFound` for a **missing collection** survives, and it changed shape while surviving.
There was never an explicit check: a missing collection produced
`.notFound(entity: "collection_item", id: <first asset>)` because the first membership
lookup missed. It is now an explicit `Collection.exists` producing
`.notFound(entity: "collection", id: <collection>)` — the same refusal, finally naming the
thing that was actually absent. An empty `orderedAssetIDs` returns before looking, as it
always did.

**One existing test changed.** `ServicesInvariantTests` ·
*"setGridOrder with a non-member rolls back the whole batch"* asserted the old throw. It is
now *"setGridOrder IGNORES a non-member and orders the rest (14A)"* and asserts the gap. It
is the only assertion in the repo that had to move.

## 2A — the export stopped drawing everything in Helvetica

`MoodboardRenderer.swift:210` was `CTFontCreateWithName("Helvetica", …)`, hard-coded, with
no paragraph style. A board whose heading was 24pt bold centred Futura exported as 24pt
Helvetica flush left, and nothing said so.

`AtelierExport.TextStyle` now carries `fontFamily: String?`, `weight: FontWeight` and
`alignment: TextAlignment`, with the two enums rawValue-matched to `AtelierCore.TextWeight`
/ `TextAlign` exactly as `CanvasRenderer`'s pair already are. `FrameStyle.label` is a
`TextStyle`, so it inherits all three at no cost. `RenderOptions` is untouched.

The resolution rule, which is the part with a decision in it: a non-empty family is
**matched** first (`CTFontDescriptorCreateMatchingFontDescriptor`, family mandatory), and a
nil match falls through to the system font. That indirection is the whole point —
`CTFontCreateWithName` on a family nothing has installed silently returns a default face,
so "the user's font is missing" and "the user asked for nothing" would have been the same
export. The weight rides as `kCTFontWeightTrait` in both branches, at the values
`NSFont.Weight` uses, so a family with a real Bold face gets that face and the system font
walks its own weight axis.

Nine tests, in the suite's existing pixel-probe style — rasters compared whole, because a
glyph's ink lands wherever the face and the alignment put it and no single named pixel
survives a font change. Alignment is asserted by where the ink MOVED (left half vs right
half), not merely that the bytes differ. An unknown family is asserted byte-identical to
asking for no family: the fallback *is* the system font, not merely some other font.

The cross-package conformance test that drives both bridges from one fixture set is P1's;
this phase only made the destination type capable of holding what the bridge will hand it.

## 3A — the origin allowlist is data

`CaptureAuth.init(token:allowedOriginSchemes:pinnedExtensionID:)`, defaulting to
`["chrome-extension"]`, and `isAllowedOrigin` now **parses** the scheme instead of
`hasPrefix`-ing it.

Parsing is not cosmetic here. `hasPrefix("chrome-extension://")` accepts
`chrome-extension://` with nothing behind it, and a list of prefixes would have needed an
exact-length check per entry to stay safe. A split on the first `://` says what it means and
refuses the three malformed shapes by name: no separator, empty scheme, nothing after the
separator. Schemes compare case-insensitively (RFC 3986); everything after `://` does not,
so a pinned gate still refuses a differently-cased extension id.

**The pin stays Chrome's.** A Safari wrapper origin carries a wrapper UUID that has nothing
to do with the Chrome extension id, so applying the pin across schemes would reject every
legitimate Safari call. It is scoped by naming the scheme, not by position in the array.

Ten new tests extend the existing twelve-case negative matrix rather than replacing it.

`CaptureServerIntegrationTests` gained the untested port-in-use path: bind an ephemeral
port, aim a second server at it, `start()` throws, `boundPort()` is nil, and the first
server is still serving. **It costs 5.4 seconds, and that is the finding.** The throw is
FlyingFox's `waitUntilListening(timeout: 5)` giving up — `CaptureServer.start()` does not
fail fast on a collision, it waits out the timeout. Nothing here changes that; it is now
written down and exercised, which it was not.

## 6A (Core) — `AtelierError: LocalizedError`

An exhaustive `errorDescription` with **no `default`**, so a nineteenth-plus case does not
compile until someone writes its sentence. The sentences are user-facing prose: they name
folders and smart collections, never tables, ids or SQLite codes.
`.persistenceFailure`'s detail is deliberately kept out of the sentence — the diagnostic
belongs in a log, and a test asserts it is still reachable via the debug description.

`notFound` carries a storage name (`"collection_item"`, `"saved_search"`) because that is
what the throwing site knows, so a small lookup turns it into a word a person has seen. That
one has a `default` and should: it is a lookup, not the exhaustive table, and an unmapped
entity degrading to "item" is better than leaking a table name at the user.

The second test is the one that matters. The enum carries payloads, so `CaseIterable` is
unavailable and the fixture list is hand-written — which is exactly the thing that falls
silently behind. So the test **reads the enum body out of `AtelierError.swift` at test
time** and compares the declared case count (19) to the list's length. Adding a case fails
the compile; adding the sentence but not the fixture fails here.

The five app-side `message(for:)` switches that this exists to collapse are P1's.

## 12A — Archive fixtures, wired

`AtelierArchive`'s test target gains `resources: [.copy("Fixtures")]` and
`Tests/AtelierArchiveTests/TestSupport/Fixture.swift` with `fixture(named:)` and
`fixtureURL(named:)`. `.copy`, not `.process`, so bytes reach the bundle unchanged — a
fixture whose whitespace a resource pipeline rewrote is no longer the file the exporter
produced, which is the entire value of committing it.

One smoke fixture (an empty but valid `manifest.json`) proves the wiring three ways: the
resource is copied, the loader returns the bytes verbatim, and a missing name throws
**naming itself** rather than returning a nil that unwraps into an unrelated crash. Existing
in-code fixtures were left alone, as the plan asked.

This is infrastructure for P18–P20, whose parsers read files other programs wrote. A parser
tested only against JSON the test itself composed is a parser tested against the author's
belief about the format.

## The split — 4,221 lines became nine files

`AppServices.swift` was one class body with twenty-three `// MARK:` sections. Each section
moved WHOLE and unchanged into an extension:

| file | lines | sections |
|---|---|---|
| `AppServices.swift` | 512 | the class, the funnel, the shared helpers |
| `+Assets.swift` | 918 | ingest, delete + undo, fields, favorites, shelf, tags, suggestions |
| `+Collections.swift` | 817 | folders, arrange / bulk, the scoped reads |
| `+Analysis.swift` | 598 | OCR, colour buckets, embeddings — and meaning search |
| `+Spaces.swift` | 478 | boards and their items |
| `+Search.swift` | 471 | keyword search |
| `+Jobs.swift` | 237 | the bulk-import ledger |
| `+Library.swift` | 193 | snapshots, integrity, storage stats |
| `+SavedSearches.swift` | 173 | smart collections |

`semanticSearchAssets` is in `+Analysis.swift`, not `+Search.swift`, because it is the read
half of the embedding lane — it shares the model-version rule, the vector codec and the
normalization contract with the writers above it, and nothing with the FTS query builder.
`+Search.swift`'s header says where it went.

### What the split cost, and what it refused to cost

A Swift extension in another file cannot see `private`. So `write`, `read`, and ten shared
statics (`key`, `membership`, `covers`, `stackPreviews`, `performDelete`,
`forgetOrphanedKnownItems`, `isFiled`, `placeIngested`, `rehomeUnfiled`,
`evictFromUnsorted`, `findDuplicate`, `findDuplicateContent`) widened to `internal`. They
remain package-internal; nothing outside AtelierCore can reach them.

**`database` did not widen.** It is still `private` to `AppServices.swift`, because it being
the one private stored property is what makes A4 — every mutation goes through the funnel —
a fact the compiler checks rather than a habit. The only caller that needed the pool
directly was `snapshot(to:)`, for the one statement SQLite refuses to run inside a
transaction, so the funnel grew a third door: `writeWithoutTransaction(_:)`, same error
mapping, `internal`. Moving a file is not worth spending that guarantee.

### `require`

```swift
static func require<T: FetchableRecord & TableRecord>(
    _ type: T.Type, db: Database, key id: UUID,
    entity: String = T.databaseTableName) throws -> T
```

**Twenty of the twenty-three `fetchOne(db, key:)` sites** were the five-line
`guard let … else { throw .notFound }` and are now one line. The other three are not that
shape and were left: one returns the optional, one is `else { return }`, one is
`else { continue }` (an idempotent skip). The `entity:` default is not a guess — every one
of the twenty passed the record's own table name by hand. The parameter survives for the
case that must differ, where a lookup's failure is reported as a different entity than the
table it read.

### The split broke a canary, and that is the interesting part

`AssetReadSurfaceTests` pins every function that reads the `asset` table by **scanning the
source of `AppServices.swift`**. Splitting the file left it scanning a tenth of the surface
while still passing its own name checks — the precise way a shape-level canary dies
unnoticed. It now **discovers** `AppServices*.swift` from the directory, so the next
extension file is scanned the day it lands with no edit.

Then it failed a second time, and better: `setName` and `setNote` had dropped off the pinned
surface, because `require` hides `Asset.fetchOne` behind a generic. A pattern was added for
it. That is a real reduction in a security-adjacent canary's coverage, arriving through a
refactor rather than a deletion, and the file exists to catch exactly that.

One bug found while fixing it, worth writing down: `#/\brequire\(/#` matches **nothing**
against `Self.require(`. Swift Regex follows UAX #29, which does not break a word on a `.`
between two letters (it is how "e.g." stays one word), so `Self.require` is one word and
there is no boundary before `require`. A `\b` there would have been a silently dead pattern.

**This is the one item where the plan said "no test changes", and two were unavoidable.**
Both are the same test file, both preserve exactly what it asserts, and not touching it
would have left the canary scanning almost nothing while reporting green — strictly worse
than the split it was protesting.

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
  ⚠ Extension

All 12 stages passed, 1 with a warning above.
```

Exit 0, `App target` at **TEST SUCCEEDED**.

**That summary is not the one this phase first produced.** P0 ran `verify.sh full` — the
first run of full mode on this branch — and got `✗ Extension`, `1 stage(s) failed`, on a
stage whose files this phase never touched. `git diff 3bf4d7e -- extension/` is empty. The
node suite passed whole; `npm run drift-check` exited 1 because the Instagram fixture had
aged past its 14-day window on **2026-08-28**, three days before this branch was cut, and
`fast` mode — eleven stages to full's twelve — does not run that stage at all, so nobody
had seen it.

The phase stopped and reported rather than committing, which is what the plan's rules say
to do. The user chose to split the two signals; that is [458](458-the-gate-tells-its-two-arms-apart.md),
committed immediately before this entry. Staleness is now exit 2 and a `⚠` stage; real
drift is still exit 1 and still fatal. The fixture is still stale and the reminder still
prints — what changed is that a calendar fact no longer masks a drift failure.

Both changes were in the tree for the run above, so it verifies the pair.

Package suites: AtelierCore 785 tests, AtelierExport 93, AtelierServer 22 + 10, AtelierArchive
all green.

## Tests added

**34 new `@Test`s; one existing test rewritten** (the `setGridOrder` non-member case).

- `AtelierExportTests` · `MoodboardRendererTests` (9) — text draws ink at all; fontFamily /
  weight / alignment each change the raster; an unknown family falls back to the system
  font; `font(family:weight:size:)` resolves family, weight and the fallback; an empty
  family is treated as none; `FrameStyle.label` inherits all three; the token enums keep the
  rawValues the domain stores.
- `AtelierServerTests` · `CaptureAuthTests` (10) — a listed second scheme accepted; an
  unlisted one rejected; the pin does not apply to the second scheme; no `://`; empty
  scheme; scheme-only; an absent origin still requires the token; scheme case-insensitivity;
  `parseOrigin`'s three refusals; CORS echoes a listed second scheme.
- `AtelierServerTests` · `CaptureServerIntegrationTests` (1) — binding a port twice.
- `AtelierCoreTests` · `AtelierErrorMessageTests` (4) — every case has a non-debug sentence;
  the hand list matches the case count read from source; `notFound`'s human noun;
  `persistenceFailure` keeps its detail out of the sentence.
- `AtelierCoreTests` · `ServicesInvariantTests` (6) — non-members ignored; a missing
  collection still throws; an empty list is a no-op; unlisted members untouched; a duplicate
  takes its last position; a reorder spanning two chunks.
- `AtelierArchiveTests` · `FixtureLoadingTests` (4) — the fixture is bundled and loads
  verbatim; it decodes through the shipped decoder; a missing fixture names itself; an
  extensionless name resolves.

`ScaleHarnessTests` gained two timed rows rather than tests: `setGridOrder` and
`semanticSearchAssets`.

## What is still NOT covered

**The Extension stage.** Red before this phase, red after it, for a reason no agent can
clear. Named above; it needs a decision.

**`CaptureServer.start()` does not fail fast on a port collision.** The new test proves it
throws, and proves it takes 5.4 seconds to do so, because the throw is a timeout rather than
the bind error. Nothing was changed. If the app's "another copy is already listening"
message matters at launch, five seconds of silence in front of it is the real behaviour and
it is not in any phase's scope yet.

**Nothing in this phase is proven end to end.** 2A's fields exist on `AtelierExport.TextStyle`
and the renderer honours them, but **no bridge fills them in** — `MoodboardExport.textStyle(from:)`
still builds a `TextStyle` with three fields, so today's export is byte-identical to
yesterday's. The conformance test AND the bridge are P1's. The same is true of 6A: the
sentences exist and nothing shows them, because all five `message(for:)` switches are in
`AtelierRefs/`. And of 14A: the service ignores non-members, and `applyOrder`'s pre-read is
still there paying for a guarantee it no longer needs.

**3A ships one scheme.** `safari-web-extension` is a test fixture here, not a configured
value; no caller passes a second scheme, and P17 is what would.

**12A has one fixture, and it is empty.** It proves the wiring and nothing about any real
export. Every parser fixture the decision actually calls for waits on files the user
supplies.

**The split is unproven beyond `swift test`.** 785 Core tests and the app's suite pass, and
that is the whole of the evidence that 3,800 moved lines moved unchanged. No behavioural
test was written for the move, by design, and none of the twenty `require` rewrites changed
an error message — but a `guard let` that became a `require` with the wrong `entity:` would
be invisible to every test that does not assert the string, and most do not.

**The harness numbers are one machine, one run, debug builds.** `swift test` builds
unoptimized; `vDSP_dotpr` is a library call and unaffected, but the decode loop around it is
not. A release build would move the semantic numbers down by some unmeasured factor. It
would have to move them down by 15× to change the P0b decision, which is why this phase did
not go looking — but the absolute numbers should not be quoted as production latency.

**P0b is scheduled, not designed.** The measurement says build it. Nothing here says the
invalidation from the two write sites is actually sufficient, and that is the property most
likely to be wrong.
