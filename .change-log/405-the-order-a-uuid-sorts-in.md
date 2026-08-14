# 405 — the order a UUID sorts in

An afternoon of shares, drained on the Mac that evening, arrived in the grid in the order
four random UUIDs happened to sort in. Not capture order, not any order — the file name is
a UUIDv4, `pendingRecordURLs()` sorts by it, and the drain walked that. `InboxRecord`
has carried `capturedAt` since S2 for exactly this, and nothing read it for exactly this.

This is **R2**, the largest slice of the review pass over
[092](../.docs/092-ios-companion-plan.md) · S2/S3, and it is one slice because five of its
six findings rewrite the same function. `InboxDrain.drainOnce()` now reads each pending
record once instead of twice, orders them by capture time, runs them through the
coordinator at the coordinator's own width instead of one at a time, creates
`inbox/failed/` at most once a pass instead of once a record, and can tell its caller that
the inbox could not be read at all. The sixth finding is that both cancellation paths were
carefully documented and never tested; they are now.

## What drain order actually affects, which is more than it looks

`makeInput` passes `now: record.capturedAt` into the decode funnel, so the asset's
`source.captured_at` is the moment the user hit share no matter when the drain runs — a
property S3 built deliberately and tests. It would be reasonable to conclude from that
that processing order is invisible and this ordering fix is only about determinism.

It is not. **Nothing in the library orders by `source.captured_at`.** Traced end to end
before writing a line of it:

| what | orders by | where |
|---|---|---|
| a collection, default | `collection_item.manual_order, collection_item.id` | `AppServices.swift:1934` |
| a collection, "Newest" | `asset.created_at DESC, asset.id DESC` | `AppServices.swift:1936` |
| a collection, "Most Viewed" | `view_count DESC, asset.created_at DESC, asset.id DESC` | `AppServices.swift:1938` |
| search, default and relevance-tie | `asset.created_at DESC, asset.id DESC` | `AppServices.swift:2921` |

`manual_order` is `MAX(manual_order) + 1`, computed per insert (`AppServices.swift:1292`),
and `created_at` is a plain `Date()` stamped inside the insert transaction
(`AppServices.swift:1127` and `:1245`). Both are functions of *processing* position.
`captured_at` is written, archived, restored — and never read by an `ORDER BY`, never a
sort key in the app target, and not displayed anywhere: the detail view's "Saved" row shows
`asset.createdAt` (`ItemDetailView.swift:1741`). There is no capture-time sort in the UI and
no way to ask for one; the only sort control is Manual / Newest / Most Viewed.

So drain order *is* grid order, in every sort mode, and the fix is user-visible rather than
merely tidy. It is also the reason the honest limit below matters.

## Ordered by capture time, read once

The pass now reads and decodes every pending record up front, sorts, and then works. That
is one change, not two, and it had to be: the old shape called `readRecord(at:)` inside the
loop, so ordering by anything *inside* a record would have meant decoding every record
twice — issue 16's second half, and the reason issue 3 and issue 16 are one edit.

Ties break on the record id, so two captures stamped in the same instant have one order
rather than whichever one the sort felt like. Records that will not decode cannot take part
in a capture-time ordering at all — having no readable `capturedAt` is what "will not
decode" means — so they are carried through the sort as their own case and given a defined
position: **first**, in file-name order among themselves. First because quarantining is
bookkeeping that touches no pipeline, so doing it before any ingest means an interrupted
pass has at least cleared out the records that could never drain; name order among
themselves because that is the order the enumeration already produced, and inventing a
second arbitrary one would not make it less arbitrary. The test for this asserts the
position, not the outcome — it looks at `failed/` from inside the first ingest, because
once the pass returns, both fates are visible whichever order they happened in.

## At the coordinator's width

`await coordinator.ingest([input])`, once per record, is a four-way bounded runner asked to
run one thing: the batch machinery entered, primed with a single task, drained, repeat. A
backlog of fifty shares decoded strictly serially through the exact code path that exists
to stop that happening.

A pass now fills a chunk, runs it, resolves every record in it — deleted, stamped, or
quarantined, matched to its outcome **by index** — and only then starts the next.

**Where the width comes from: the coordinator.** `IngestCoordinator.maxConcurrent` was
private and is now `public nonisolated let`. The alternative was a constant on the drain,
and two numbers meaning "how much of this machine we spend decoding images" is one number
with a second copy that will disagree the first time either is tuned. `nonisolated` because
reading a batch width should not cost an `await` on the actor that is busy running the
previous batch; `let` and not `var` because it is a number a caller may size a batch by and
must never set.

**Ordering within a chunk: preserved between chunks, not inside one.** This is the tradeoff
and it is worth stating plainly rather than burying. The records in a chunk run
concurrently and take their `manual_order` / `created_at` from whichever insert transaction
commits first, so four shares that went out together can still land among themselves in any
order. Given the table above, that is genuinely user-visible: capture order is now exact to
within the chunk width. Four positions of slack, against a backlog that had *no* order at
all an hour ago, in exchange for the concurrency the coordinator exists to provide. The
alternative — a chunk size of one — would keep the ordering exact and quietly undo issue 13
while appearing to fix it, which is why it was not taken. The durable fix is not in this
package: it is ordering the library by `source.captured_at`, which changes what every
producer's captures mean and belongs to whoever decides that.

The crash window widens with it, from one record to one chunk, and the header's existing
argument covers the new width unchanged: a chunk interrupted after two of its four ingests
leaves two records whose assets are already in the library, and 18A blob-hash dedup
resolves the re-run onto those assets rather than duplicating them. That property was
already the thing making a mid-drain crash cheap; it is now also the thing making a wider
window affordable.

## An unreadable inbox said "nothing was shared"

`guard let pending = try? layout.pendingRecordURLs() else { return summary }` returned
`DrainSummary(0, 0, 0, 0)` — the same value as a completely normal launch. A vanished App
Group container, a data-protection denial and "the user has never shared anything" were one
value, and the first two are the ones worth a diagnostic.

`DrainSummary` gains `inboxUnreadable: Bool`. Deliberately not a fifth count: no record was
reached, so it is not a fate a record had, and folding it into the counting would break the
one property the four counts have — that they add up to the records the pass saw. The
never-throws contract is untouched, because S4's launch wiring depends on it and the
header argues for it well: a drain is something the app does on the way to somewhere else
and must never be what stops it.

No logging was added. `AtelierIngestion` has no logging opinion and acquiring one for this
would be a worse trade than the flag; the caller that will show something to a user is in
the app target, and it now has something to show.

## The default that was stated five times

`decoded.collectionID ?? Collection.unsortedID` appeared at five call sites across
`makeInput`'s two switches — five chances for a future kind to acquire a different default
by nobody's decision, surfacing months later as "some shares go to the wrong place". It is
now `targetCollection(_:)`, once.

The two switches themselves are deliberately left alone. They differ in the type of the
argument they build (`imageData: Data` against `fileURL: URL`), and collapsing them would
mean a generic or an enum-of-sources for two call sites — a shape that has to be understood
before either branch can be read, standing in for a duplication that is four lines long.

Same reasoning, applied a second time: `pass.summary.quarantined += 1` sat at each of the
three call sites of `quarantine`, and now sits inside it. A fourth call site could
previously move a capture out of the inbox without saying so in the summary.

## `failed/` is made once a pass

Two call sites issued `createDirectory(at: layout.failed)` per quarantined record. A pass
that quarantines forty records made forty syscalls to create one directory.

The pass now carries an `InboxDrain.Pass` — the summary being accumulated, and a flag for
whether the directory has been prepared — threaded `inout` through the resolution helpers,
because `InboxDrain` is a value with no mutable state and two passes over one inbox share
nothing. Lazily, not up front: a pass that quarantines nothing must not leave an empty
`failed/` behind, since `failed/` existing is exactly the signal to a human that something
went wrong. There is now a test that a clean pass does not create it, and one that two
quarantines from the two different call sites in a single pass both land.

## Both cancellation paths, finally asserted

`if Task.isCancelled { break }` and `case .cancelled?, .none:` each carried a careful
comment about attempts and counting, and `DrainSummary`'s doc promised that a cancelled
record is "deliberately in none of them". Nothing tested any of it, so nothing would have
noticed the promise breaking.

They are tested two different ways, because they are two different claims.

**A pass cancelled mid-flight** is driven through `IngestPipeline`'s existing `timing`
sink. It is emitted once per successful byte ingest, from inside the ingest, so a test can
cancel the surrounding task from *within* a live pass — no sleeping, no polling, no window
in which the pass might have finished first. Three records at width one: the first is
ingested and counted, and the two the pass never reached are asserted untouched — still
pending, still at zero attempts, payloads intact, `failed/` never created — after which an
uncancelled pass finishes the job, since the inbox is the accounting that survives.

**A `.cancelled` outcome** is driven by calling `resolve(_:outcome:into:)` with it.
`IngestCoordinator` is a concrete actor over a concrete pipeline with nothing to stub, and
that is not the whole reason: now that a chunk is never wider than the coordinator,
`runBounded` primes every slot in it at once, so a `.cancelled` outcome can only arise in
the window where cancellation lands between the drain's own check and the batch being
primed. That window cannot be opened deterministically from outside, and a test that tried
would be the flaky kind that passes three times and fails on the fourth. So `resolve` is
`internal` rather than `private` — the same accommodation `makeInput` already had, for the
same reason — and the rule is asserted where it is implemented: a `.cancelled` outcome
spends no attempt, moves no counter, and leaves the record in the inbox. `nil`, the
impossible case of fewer outcomes than inputs, is asserted to behave identically.

No production seam was added to make any of this testable. The pipeline, the coordinator,
the writer and the drain are the real ones in every test in the file.

## Verification

Fourteen new tests, all seventeen existing ones unchanged — no assertion was edited, so
nothing in this slice is a behaviour change to something already pinned. The
`AtelierIngestion` suite was run three times because this slice changes concurrency; it was
stable at 462 every time, with no `ColorExtractorTests` tie-break flake in any run.

| | |
|---|---|
| `AtelierIngestion` | **462 / 47** — was 448 / 47; three consecutive runs, identical |
| `AtelierCore` | 760 / 105 — unchanged |
| `AtelierCapture` | 77 / 4 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| extension | 535 / 535 `node --test`; `drift-check` reports no drift |
| macOS app | `xcodebuild build`, `platform=macOS` — **BUILD SUCCEEDED** |
| iOS Debug | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |

The ordering test is built so it cannot pass by luck: the four record ids are generated,
sorted by name, and then handed *increasing* capture times in reverse, so file-name order
is the exact reverse of capture order. It runs at width one so that the order ingests are
reported in is the order the pass walked — inside a wider chunk that order is unspecified
by design, and a test asserting one would be asserting the tradeoff away.

## Files

    AtelierIngestion/Sources/AtelierIngestion/    `drainOnce()` reads each record once,
      Input/InboxDrain.swift                      orders by `capturedAt` (undecodable
                                                  records first, by name), and runs chunks
                                                  of `coordinator.maxConcurrent`, resolving
                                                  each by index; new `Pass` state (summary +
                                                  one `failed/` create); new
                                                  `resolve(_:outcome:into:)`,
                                                  `prepare(_:into:)`, `run(_:into:)`,
                                                  `orderedEntries(of:)`,
                                                  `targetCollection(_:)`;
                                                  `DrainSummary.inboxUnreadable`; the header
                                                  gains the ordering and chunking arguments
                                                  and the crash window is restated
    AtelierIngestion/Sources/AtelierIngestion/    `maxConcurrent` is `public nonisolated
      Pipeline/IngestCoordinator.swift            let` — the width a producer sizes its
                                                  batches by, readable without an `await`
    AtelierIngestion/Tests/                       +14 tests: capture-time order and its
      AtelierIngestionTests/                      tie-break, undecodable records' position,
      InboxDrainTests.swift                       the unreadable-inbox flag against an empty
                                                  inbox, chunking across and within
                                                  boundaries, index-matched fates, `failed/`
                                                  created once and only when needed, both
                                                  cancellation paths; plus `IngestWatcher`,
                                                  `Latch`, `TaskBox` and `Gate`, the
                                                  test-side machinery for standing inside a
                                                  running pass
    AtelierCapture/Sources/AtelierCapture/        comment only — `pendingRecordURLs()` no
      InboxLayout.swift                           longer calls its file-name sort
                                                  "oldest-name-first", which it never was
    .docs/092-ios-companion-plan.md               a dated note under S3

## Migration notes

None for users. Nothing about what a capture becomes changed — the same records produce the
same assets in the same collections with the same timestamps. What changed is the order
they are processed in, how many at a time, and what the caller is told about a failure to
enumerate.

**`DrainSummary` gained a field.** `inboxUnreadable: Bool`, defaulted to `false` and last in
the initializer, so every existing construction and every existing `==` against a
four-count literal still compiles and still means what it meant. What it is source-breaking
for is an *exhaustive* initializer outside this repo — anything constructing the struct
positionally, or any code (a test double, a serializer) that enumerates the fields — and
semantically breaking for a comparison that expects `DrainSummary()` from an inbox that
cannot be read. That comparison was the bug.

**The drain now runs up to `maxConcurrent` captures at once.** A caller that shared the
coordinator with something else and relied on the drain leaving three of four slots free
will see it use all four. It is the same coordinator, so nothing is oversubscribed; it is
simply no longer under-subscribed.

**`resolve(_:outcome:into:)` and `InboxDrain.Pass` are internal API.** They exist at that
access level for the tests and are not part of the package's public surface; the entry
point is still `drainOnce()`, which still never throws.

For anyone extending this file: a new fate for a record means a new counter on
`DrainSummary` **and** a call inside the helper that performs it, not at the call sites.
That is the shape `quarantined` was corrected into, and the reason is that the summary is
compared as a value in every test — a fate that moves a capture without moving a counter
fails as a mismatch somewhere else, days later.
