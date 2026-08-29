# 396 — the drain owns nothing

The fourth slice of the iOS companion ([092](../.docs/092-ios-companion-plan.md) ·
S3). The host's half of the handoff: `InboxDrain`, which takes the captures
[395](395-the-record-is-the-commit-marker.md)'s writer left in a directory and runs
them into the library.

It is the last slice that needs no iOS target, no device and no provisioning — and
with it landed, the whole capture-to-library path is provable under `swift test` on
macOS. A fixture inbox, written by the real `InboxWriter` the share extension will
link, drains into a real migrated SQLite library through the real coordinator, and
the assertions are about what is left on disk afterwards.

The name is the design. The drain has no queue, no timer, no worker, and no state
between calls. Everything it knows it reads off the disk each pass, which it has to
anyway: the producer is another process that may have run before the last reboot.

## No second queue

The obvious shape for "drain a directory of pending work" is a runner with its own
concurrency, its own retry policy and its own progress. This is not that, for the
same reason `startCaptureEndpoint` (`IngestionModel.swift:885`) is not. There is
already exactly one bounded `IngestCoordinator` in the app and every ingest path
funnels through it; a second runner would mean two things deciding independently how
much of the machine to spend decoding images, on a laptop that is also doing
something else.

So the inbox is a *producer*, the second one, and it does what the first one does:
map its captures through the same `CaptureDecoder` funnel and the same
`DirectInputReader.remote*` factories, then hand the coordinator an `IngestInput`.
That sharing is not tidiness. 18A dedup keys on provenance, and two decoders over one
wire shape drift in the direction that forks assets quietly rather than crashing.

## No timer either

`drainOnce() async -> DrainSummary` runs the inbox as it stands and returns what
happened. There is no `start()`, no `stop()`, no `DispatchSource`. The caller owns
cadence — at launch, on foreground, from a watcher — and the library has no opinion
about which, because "when should a phone's shares appear on the desktop" is an app
question and this package cannot answer it.

The immediate payoff is that every test is deterministic with nothing to wait on, and
that a second pass is a way to *observe what the first one left behind*: the
quarantine-after-three test is literally three calls and three assertions on the
record between them.

`DrainSummary` is `Equatable` and counts the four terminal fates of a record —
ingested, skipped as incomplete, quarantined, failed-and-retrying. Tests assert a pass
as a value, so a pass that quietly did a fifth thing fails the comparison rather than
slipping past an assertion that only checked the one number it cared about.

## The bytes never leave the disk

This is the property the whole handoff exists for, and it is a single enum case:
`ByteSource.fileURL`, never `.data`. The extension wrote the media to a `.bin` sidecar
precisely so no process would hold it in memory; reading it into a `Data` at the last
step, to hand it to a pipeline that is only going to write it back out to a blob,
would undo that for nothing.

Making that reuse honest needed two small seams rather than a re-derivation:

- **`CaptureDecoder.decodeInput(_ request:now:)`** — the existing body-taking entry
  point is now *decode the JSON, then run this*. The inbox's capture arrives as a
  `CaptureRequest` nested in an `InboxRecord`, never as a loose body, and a funnel
  reachable only through a deserializer is a funnel with a second copy waiting to be
  written. Pure refactor; the whole malformed-input matrix passes unmoved, and a new
  test asserts the two entry points agree.
- **`CaptureDecoder.decodeFileInput(_:now:)` → `DecodedFileInput`** — the same kind
  validation, provenance validation and routing, for a capture whose bytes are a file
  the caller already holds. It carries no bytes at all, and the two cases reuse
  `DecodedVideoCapture` and `DecodedContentCapture` rather than declaring a fourth
  near-identical struct: the streamed video upload had exactly this problem first, and
  that shape was always about transport rather than media type.

`DirectInputReader` gained `remoteFile` (which `remoteVideo` now delegates to, since
it was already this) and `remoteContentWithFile`. The last pair is deliberately not
collapsed into one factory with a `ByteSource` parameter — the choice between `.data`
and `.fileURL` is the one thing this path must not get wrong, so it is spelled at the
call site both times.

## Three decisions the plan left open

**A malformed `payloadFile` quarantines immediately, with `attempts` untouched.** S2's
`InboxLayout.payloadURL(named:)` refuses anything that is not a single plain path
component, so a hostile record cannot make the drain read or delete outside the inbox.
When it refuses, the record goes straight to `inbox/failed/` on the first pass. A
rejected filename is malformed, not transient — it will never become valid, and
spending three passes proving that is waste. The attempts budget is for failures that
might not happen again: disk, decode, coordinator pressure.

The same reasoning, forced rather than chosen, covers a `.json` that will not parse.
There is nowhere to put an attempt count on a record that will not decode, so
quarantine is the only terminal state available — and a record is committed by an
atomic move, so what is on disk is whole or is not there, which makes undecodable mean
malformed rather than early. Its sidecar is guessed from the writer's naming
convention and goes with it, rather than leaking.

**S3 stops at the library. No app-target changes at all.** 092 · S3 said "wire it into
the Mac app behind the `-library-root` override and exercise it by dropping records
into a scratch library". The wiring moves to S4; the exercising happened here, in
tests. Wiring a drain into the app now would mean a call site whose only possible
input is a directory nothing writes to — the producer is an iOS share extension that
does not exist until S4 — so it would be dead code plus a UI-refresh hook with nothing
to refresh from. `IngestionModel.swift` was read as the model for the coordinator
seam and left untouched, and `project.pbxproj` needed no change, for the fourth slice
running.

**Target collection is `collectionId ?? Collection.unsortedID`** — the same default
the capture endpoint already applies (`IngestionModel.swift:893`). This settles 091's
open question 2: a share with no context lands in Unsorted, exactly where a browser
capture with no target lands. No inbox collection, no picker in the extension, no
read-only collection tree crossing the process boundary. Two tests hold both halves,
including that a defaulted capture does *not* appear in some other collection.

## Deletion is ordered too, in the opposite direction

The record and its payload are removed only after the coordinator reports `.ingested`.
Dying before that re-runs the item next pass, and 18A blob-hash dedup resolves the
re-run onto the asset already there — so a crash mid-drain costs a duplicate
*attempt*, never a duplicate asset. That is asserted directly: ingest a record, write
the identical record back (the exact state a crash between "ingested" and "deleted"
leaves), drain again, and the library still has one asset and one blob.

Within the deletion the record goes **first**, the inverse of the writer's order and
for the mirror-image reason. A payload with no record is a few leaked bytes nothing
enumerates. A record whose payload has been deleted is permanently incomplete, and
`isComplete(_:)` would skip it on every pass forever — a wedge, not a leak.

Incomplete records are skipped rather than failed for the same reason S2 wrote the
payload first: a `.json` naming a `.bin` that is not there is a writer mid-flight, not
data loss. It costs no attempt, and a test rewinds to that instant and then completes
the write to show the next pass ingests it.

## Rewriting a record reuses the writer

Quarantine after three attempts means stamping `InboxRecord.attempts` and re-committing
the record, and a record rewritten in place is exactly the torn-write hazard the two
phases were built for — a drain that died mid-encode would leave truncated JSON where a
valid capture had been, turning a retryable failure into a lost share. Rather than a
second, subtly less careful commit path in `AtelierIngestion`, `InboxWriter` gained
`rewrite(_:)`, and its phase 2 became a private `commitRecord(_:replacingExisting:)`
that both callers share. The flag picks `replaceItemAt` over `moveItem` — a rewrite has
a file at the destination by definition — and picks nothing else; the staging and the
discipline are identical.

The payload is not touched by a rewrite. The capture is still perfectly good; only the
counter beside it moved.

`inbox/failed/` is a plain subdirectory, not a dot-directory: `.staging/` hides because
an in-flight write must be invisible, but a quarantined capture is something a human is
meant to find. Both are invisible to `pendingRecordURLs()` for the same reason — it
takes only top-level `*.json`, and a directory has no extension — which is now tested
rather than assumed, with a decoy record planted in each.

## Files

    AtelierIngestion/Sources/AtelierIngestion/Input/InboxDrain.swift
                                                        new — `InboxDrain`,
                                                        `DrainSummary`, one pass
    AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputReader.swift
                                                        `remoteFile`,
                                                        `remoteContentWithFile`;
                                                        `remoteVideo` delegates
    AtelierIngestion/Tests/AtelierIngestionTests/InboxDrainTests.swift
                                                        new — 16 tests
    AtelierIngestion/Package.swift                       test target gains
                                                        AtelierCapture +
                                                        AtelierCaptureTestSupport
    AtelierCapture/Sources/AtelierCapture/CaptureDTO.swift
                                                        `decodeInput(_:now:)`,
                                                        `decodeFileInput(_:now:)`,
                                                        `DecodedFileInput`,
                                                        `mediaLessKind`
    AtelierCapture/Sources/AtelierCapture/InboxWriter.swift
                                                        `rewrite(_:)` and the shared
                                                        `commitRecord`
    AtelierCapture/Sources/AtelierCapture/InboxLayout.swift
                                                        `failed`, `failedURL(named:)`,
                                                        one component guard
    AtelierCapture/Tests/AtelierCaptureTests/CaptureDecoderTests.swift
                                                        4 tests — entry-point
                                                        equivalence, file routing
    AtelierCapture/Tests/AtelierCaptureTests/InboxWriterTests.swift
                                                        1 test — rewrite in place
    .docs/092-ios-companion-plan.md                      S3 "As built"; what S4
                                                        inherits now that S0–S3 are
                                                        done

`AtelierIngestion` 445 tests in 47 suites → 461 in 48. `AtelierCapture` 38 in 2 → 43
in 2. `AtelierServer` 62 in 6, unchanged. All passing; the app's `xcodebuild build`
succeeds.

The changed `AtelierCapture` sources were type-checked against the iPhoneOS SDK again
(`swiftc -typecheck -target arm64-apple-ios26.0 -swift-version 6`, capture contract
stubbed, passes) — including `replaceItemAt`, the one new Foundation call on that
side. A real iOS build still cannot run: the platform-pin blocker 395 recorded is
unchanged, and is S4's.

## Migration notes

None for users, and nothing is wired. `InboxDrain` exists in the library and has no
call site outside its tests; the Mac app is byte-for-byte unchanged in behaviour.
No stored shape, wire shape or endpoint changed, and `InboxRecord`'s on-disk format is
exactly what S2 shipped — `attempts` was already there, which is why the drain needed
no format change to stamp it.

For the build: `AtelierIngestion`'s **test** target now depends on `AtelierCapture` and
`AtelierCaptureTestSupport`, so a clean checkout resolves those products for tests as
well as for the library. No `project.pbxproj` change; no new package platform pins.

Two API notes for whoever wires this in S4:

- `CaptureDecoder.decodeInput(body:now:)` is unchanged and still the HTTP entry point.
  The new `decodeInput(_:now:)` overload is additive; existing call sites resolve to
  the same function they always did.
- `InboxDrain` has no completion hook. `CaptureRoutes` takes an `onCapture` closure so
  the app can refresh the live UI, and S4 will want the same thing here — it was left
  out rather than shipped with no caller, since a callback nothing invokes is a
  callback whose main-actor hop has never been tested.
