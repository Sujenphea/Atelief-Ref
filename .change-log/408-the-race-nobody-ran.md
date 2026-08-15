# 408 — the race nobody ran

`InboxWriter`'s header argues its central design at length: the write is two-phase
*because* "the writer and the drain are separate processes with no lock between them",
and the phase order is what makes every intermediate state legible to a reader who might
arrive at any instant. Thirty-one tests stood behind that argument and not one of them
ever ran a writer and a drain at the same time. Every torn state they check was
**hand-built** — a payload deleted after the fact, a `.json` that was never valid —
which pins the drain's *reaction* precisely and says nothing about what the writer can
actually produce. The claim that the writer can only ever leave states the drain
survives was asserted by prose.

This is **R6**, the last code slice of the review pass over S2/S3/S4b. Two items: the
test that was missing, and a comment about a test that is deliberately not being
written.

## The race, and the shape that keeps it honest

One test, run four times per execution. A real `InboxWriter` commits twenty-four
captures — cycling `PayloadSource.data`, `PayloadSource.fileURL` and media-less, so both
of the writer's staging paths and the shape with no first phase at all are in flight
together — into an inbox that a real `InboxDrain` is passing over the entire time. Two
structured tasks, one filesystem, no fakes anywhere: the same `TempPipeline` the rest of
the suite uses, a real migrated SQLite library, the real bounded coordinator.

The risk in a test like this is not that it fails. It is that it *sometimes* fails, and
this repo already carries one flake it does not need a second of. So the rules were set
before the code:

**Nothing timing-shaped is asserted.** Not how many captures a given pass ingested, not
how many passes ran, not which task got there first — every one of those is a fact about
one machine on one afternoon. What is asserted holds at every interleaving. The counts
that must be zero are zero; the *sum* of `ingested` over every pass plus the final one is
exactly the plan's size, because each capture ingests exactly once however the passes
happen to divide them up; and the set of captures in the library is compared to the set
that was written, by identity rather than by count. Every capture is distinct in every way
identity is decided — distinct bytes, distinct link URLs, distinct capture times — because
18A dedup collapsing two identical captures would make "nothing was duplicated" true of a
library that had quietly thrown one away.

**No `sleep`, no polling with a timeout, no wall clock.** The drain loop ends when the
writer's `defer` says the producer has stopped, and the writer always reaches it, throw
or no throw. The final accounting runs after both tasks have returned, when nothing is
moving — so the arithmetic at the end is arithmetic, not a snapshot of a race.

**The one place a timing dependence could have crept in is the mid-flight check**, which
asks whether every committed capture is in the inbox *or* in the library. The two reads
are ordered, and the order is load-bearing: the drain deletes a record only after the
ingest transaction commits, so a record found missing by the first read had its asset in
the library before that read, and the second read is guaranteed to see it. Reading the
library first would invert exactly that and manufacture a failure out of a capture that
ingested in between. That is written down beside the function, because it is the kind of
thing that gets "simplified" into a flake.

**And the two tasks have to actually overlap**, which took a wrong turn worth recording.
The obvious tidy-up — precompute every capture's PNG before the race starts so the write
loop is nothing but the two-phase commit — makes the race stop happening: the writer
finishes twenty-four commits in a few milliseconds, and the drain gets **one pass per
round** (measured) before the loop condition is already true. With the fixture work left
where a share extension does it, between captures, the drain gets **200–1,000 passes per
round** and ingests half the backlog while the writer is still going. The gap between
captures is what puts the two in the same time domain, and hoisting it out optimised the
test into a no-op.

## What it proves

`skippedIncomplete == 0` is the ordering claim itself, and it is the assertion that
bites. That counter is incremented for a record the drain found without its payload —
precisely the state the writer's phase order says it cannot leave behind. Hundreds of
enumerations per round land inside a live write, and not one of them may see one.

That was verified by mutation rather than assumed: reversing the writer's two phases so
the record commits first fails this line in **all four rounds** (1–3 half-committed
records observed per round), and *nothing else in the test notices* — the drain skips
them, the next pass picks them up, and every other assertion still passes. The
end-state accounting cannot see an ordering bug; only the count taken mid-race can.

Alongside it: `quarantined == 0` (a torn record read as malformed — what the atomic
`rename` prevents), `retrying == 0` (a torn record read as *failed* rather than as early,
which would spend an attempt on a capture that was merely young), the mid-flight
loss check, the exact ingest total, the exact set of `source.capturedAt` in the library,
the blob count, and an inbox that ends holding nothing but an empty `.staging/`.

## What it does not prove, which matters as much

It is **two tasks in one process against one filesystem.** What ships is an app and an
extension: two address spaces, two schedulers, one of which can be jetsammed mid-write.
None of that is here. There is no memory ceiling, no data-protection class, no App Group
container, and no way for one side to die between phases — the crash case the writer's
header discusses is still covered only by the hand-built fixtures.

What is genuinely exercised is that `rename(2)` within a volume publishes a file whole
and in order, and that the drain's reaction to what that produces is correct. **iOS's own
ordering guarantees are not what this runs**, and no number of green rounds on a Mac
would make them so. The test closes the gap between "the design is argued" and "the
design has been run"; it does not close the gap between a laptop and a phone.

## Five runs, and twelve more

The point of a race test is worthless if people learn to re-run it. `AtelierIngestion`
was run five times end to end: **463 / 47 passed, identically, five times out of five.**
The race test alone was then run twelve more times under `--parallel`, with the rest of
the suite's load around it: twelve for twelve. Zero non-deterministic outcomes across
seventeen executions and sixty-eight rounds.

The suite cost is ~0.9 s for the whole `InboxDrain` file, up from ~0.7 s.

## The iOS residue, named

`LibraryLocation`'s `#if os(iOS)` branch is three things — the
`containerURL(forSecurityApplicationGroupIdentifier:)` lookup, the
`appGroupContainerUnavailable` throw when it returns nil, and the
`completeUntilFirstUserAuthentication` attribute — and all three have run exactly once,
by hand, on a simulator during S4b-i. **No iOS test target was added for them, and the
file now says so in its own words.**

The argument is that a test there would assert nothing about this code. What is inside
the `#if` is three Apple API calls and a `guard`; a unit test around them would stand up
a fake `FileManager` and then assert that `FileManager` does what `FileManager` does. The
two failures that matter — a container the entitlement does not actually grant, and a
file the phone will not open — are unreachable from any process that is not a real,
provisioned, *locked* device, and the protection class in particular is meaningless
anywhere else: its entire purpose is what happens to an `open()` before the first unlock
after a boot, and a simulator, a Mac and a unit test all answer that question the same
wrong way.

What is tested is everything the residue is wrapped in, and that is why the
platform-specific part was made this small in the first place: the identifier parse and
its blank cases, the root's name and creation, the override argument and environment
variable and their precedence are all platform-free and both platforms route through
them. The honest coverage claim for what is left is one manual simulator run — recorded
in the file rather than implied by silence.

## Verification

| | |
|---|---|
| `AtelierCore` | 765 / 106 — unchanged |
| `AtelierCapture` | 93 / 4 — unchanged |
| `AtelierIngestion` | **463 / 47** — was 462 / 47 |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| `AtelierIngestion`, ×5 | 463 / 47 passed on every run — identical output five times |
| race test alone, ×12 | passed 12 / 12 under `--parallel` |
| mutation check | writer's phases reversed ⇒ `skippedIncomplete == 0` fails in all four rounds |
| `AtelierRefs` | `xcodebuild build`, `platform=macOS` — **BUILD SUCCEEDED** |
| `AtelierCapture` for iOS | `swift build --triple arm64-apple-ios26.0` — **Build complete** |

## Files

    AtelierIngestion/Tests/                      +1 test (×4 rounds): a real `InboxWriter`
      AtelierIngestionTests/                     racing a real `InboxDrain` over one inbox,
      InboxDrainTests.swift                      with the invariant, the ordering count and
                                                 the final accounting. New file-scope
                                                 helpers: `RaceShape`, `RaceCapture`,
                                                 `RaceLog` (committed captures + the
                                                 producer-stopped flag, one lock), and
                                                 `RaceObservations` (a tally, not a log of
                                                 every pass). The file header gains a
                                                 paragraph on where the race test stands
    AtelierCapture/Sources/AtelierCapture/       comment only — names the three untested
      LibraryLocation.swift                      `#if os(iOS)` calls, what they were
                                                 exercised by, and why a unit test for them
                                                 would be a test of Foundation
    .docs/092-ios-companion-plan.md              dated note: the review pass is complete,
                                                 which slice closed what, and the one item
                                                 still outstanding

## Migration notes

**None.** One test and one comment. No production behaviour changed, no type gained or
lost a member, no on-disk format moved, and no existing assertion was edited.
