# 407 — the drain nobody called

`InboxDrain.drainOnce()` was written in [396](396-the-drain-owns-nothing.md), hardened in
[403](403-a-record-that-named-its-neighbour.md), rewritten around six findings in
[405](405-the-order-a-uuid-sorts-in.md), and covered by 462 tests across 47 suites. It had
never run outside one. Nothing in `AtelierRefs` referenced the type, the app target had
not changed since S3 was planned, and a capture shared from the phone reached
`inbox/` and stopped there — permanently, on a real user's machine, in silence. Every
piece of the handoff existed and the path did not.

This is **R3**, and it is one call site, one notification observer, and one column.

## Launch, and every activation

`drainOnce()` runs once at launch, from `IngestionModel.bootstrap()` after the capture
endpoint is up, and again on every `NSApplication.didBecomeActiveNotification`.
**No timer and no directory watcher**, both of which were considered and are the wrong
shape here for the same reason: an empty inbox costs one `contentsOfDirectory` call, so
the question is not what a pass costs but how many passes are spent on nothing. A timer
spends one every interval forever. An `FSEvents` watcher would be a second lifetime to
own and a second failure mode to reason about, and it would *still* need the launch pass,
because most of what a watcher would have seen arrived while the app was not running.

Activation is the cheap approximation of "something may have arrived". Records reach the
inbox by AirDrop or iCloud Drive while the Mac app is already open, and the moment the
user comes back to the window is both the moment they might go looking for the capture
and a moment the app is already awake. It is not a guarantee — a share that lands while
the app is frontmost sits until the next activation — and that is the honest bound of an
activation-driven cadence, stated rather than papered over.

**Overlapping passes cannot start.** Activation fires more often than it looks like it
does: ⌘-Tab away and back, a second window raised, a Finder drop onto the icon. Two
concurrent passes over one directory would race each other's deletes — both enumerate the
same record, both decode it, both hand it to the coordinator, and the second `removeItem`
unlinks a file the first already took. 18A dedup means the outcome is not a duplicate
*asset*, but it is duplicated decode work and a summary that double-counts. So a pass in
flight is held in `InboxDrainScheduler.currentPass`, and an activation that finds one
there is **dropped, not queued**: the drain re-enumerates the directory from scratch every
time, so whatever the dropped activation would have found, the running pass will see. The
guard is correct because the scheduler is `@MainActor` — the read of `currentPass` and the
write that claims it are one synchronous step with no suspension between them, so there is
no window for a second activation to slip through. That is the whole mechanism; there is
no lock and no flag that could disagree with the task handle.

## The cadence is a type, and it is not in `AtelierIngestion`

`InboxDrainScheduler` is a new ~90-line `@MainActor` class in the app target holding
exactly three things: when a pass runs, that no two run at once, and what the app does
with the summary. It takes the pass as a closure.

This is not mockability for its own sake, and the alternative was tried first. A real
`InboxDrain` over a real directory finishes in microseconds, so "two activations did not
overlap" could only ever be asserted by luck — the interesting case is the one that
cannot be produced on demand. With the pass injected it is the *deterministic* case: the
test parks a pass on a gate, fires three activations into it, and asserts that none of
them started a second. What a pass does to records is not re-tested here; that is
`AtelierIngestionTests`' 462, against real files.

It is also the shape the drain's own header asked for. `drainOnce()` deliberately owns no
cadence so the caller can drive it from launch, from foreground, or from a test; putting
the cadence in `IngestionModel` instead would have buried it in a 3,700-line
`@MainActor` god-object where the only way to reach it is to open a library. The
precedent is `ClipboardWatcher`, which does the same thing with an injected `board` and
`frontmostApp`. Each test drives its **own** `NotificationCenter`, so a case cannot be
woken by the test runner's app becoming active around it.

## The return value drives the refresh, and no callback crosses the line

`drainOnce()` returns a `DrainSummary`; the grid refreshes when `ingested > 0`. **No
`onCapture` hook was added to `InboxDrain`** — keeping `AtelierIngestion` free of a
UI-shaped seam is the property S3 was protecting, and the summary already carries
everything the decision needs. A pass that only quarantined, retried or skipped an
incomplete record changed nothing the grid shows and refreshes nothing.

The refresh reuses the endpoint's path rather than growing a second one.
`handleRemoteCapture` did the work inline; its two lines are now
`refreshAfterIngest(touching:)`, which both producers call. The parameter is optional and
the drain passes `nil`, because the two producers know different amounts: the HTTP route
handles one capture into one named collection, while a pass resolves each record's *own*
target and reports only counts. `nil` means "somewhere", and the response is to reload the
visible folder unconditionally. That is a wasted query when the drain landed elsewhere,
and it is the right trade against a grid that silently omits a capture the user just
watched arrive.

**An unreadable inbox is logged and nothing else** (20A). It goes to `AppLog.capture`, the
category the rest of the capture path already writes to — no second logging mechanism, no
toast, no alert. A vanished container or a permissions failure is a condition the user has
no lever for, which is exactly what [093](../.docs/093-ios-visual-design.md) argues against
raising error UI for; the captures are still on disk and the next pass will find them. A
quarantine is logged at the same level for the same reason, and a pass that did anything
at all logs one `notice` line with its counts.

## `created_at` is the capture time now

Both `AppServices` insert sites — `ingest` and `ingestContent` — stamped `createdAt:
Date()`. They now read `capturedAt` off the source draft the row is built from.

This matters because `created_at` is what the library **orders by**. A collection sorts by
`manual_order` or `asset.created_at DESC`; search orders by `created_at DESC`; the paging
cursor is `(created_at, id)`. Nothing anywhere orders by `source.captured_at`, which 405
found the hard way and worked around by ordering the *drain* instead. So `created_at` is a
display fact about when the user took the thing, not an audit fact about when a row was
written — and the two were the same instant for every producer the app had. Paste, drag,
the clipboard watcher and the capture endpoint all pass `capturedAt: Date()` at the moment
they hand bytes over. **Nothing about their behaviour changes.**

The two producers that are *not* happening now both change, and both wanted to:

- **The inbox.** A record may be drained days after it was shared. It should land where
  the user's Tuesday afternoon put it, not at the top of the grid because the Mac was next
  opened on Friday. This also retires the slack 405 had to accept: within a chunk of four,
  records commit in whatever order the coordinator finishes them, and until now that order
  *was* the grid order. It no longer is — `created_at` comes from the record, so a chunk
  can commit in any order it likes and the grid still reads in capture order.
- **Archive import (068).** This is **a deliberate change to a shipped feature**, and it is
  the reason the finding is worth stating plainly: a restored library used to collapse to a
  single instant under every sort but Manual, because every row was stamped with the minute
  of the import. Its "Newest" was really "whatever order the importer replayed in". The
  archive manifest has carried each source's real `capturedAt` since 068, so the fix is a
  read of something the format already stored — no manifest change, no version bump, and an
  archive written by an older build restores with better ordering than the build that wrote
  it.

**No existing test pinned the old behaviour**, which was checked rather than assumed: all
760 `AtelierCore` tests and the whole `AtelierRefsTests` suite pass with no assertion
edited. That is a small finding in itself. `LibraryArchiveRoundTripTests.fullRoundTrip`
asserts manual order verbatim and asserts `source.capturedAt` field-for-field, but it never
looked at `asset.createdAt` and never read a collection in any sort but `.manual` — so the
one test whose entire job is "a library survives the round trip" could not have seen this.
That gap is now closed by a case in the same suite rather than a parallel one.

Deliberately **not retroactive**. Rows already in a library keep the `created_at` they were
stamped with. Rewriting history to fix an ordering is a worse trade than one seam between
old rows and new, and the seam is invisible in practice: for every producer that existed
before this change, the two values were the same.

## What ran on macOS

A build is not evidence, and this slice's entire claim is that a path now connects. The
Debug app was launched against a scratch library through the `-library-root` escape hatch,
with records written by the **real `InboxWriter`** from a throwaway executable linking
`AtelierCapture` — the producer under test is the production one, not hand-written JSON.

**The launch pass.** One record staged before launch, `capturedAt` 2025-01-15T00:00:00Z,
with a real 64×64 PNG sidecar:

    inbox/5A3797F3-….json   {"attempts":0,"capturedAt":1736899200,…,
                             "payloadFile":"5A3797F3-….bin"}
    inbox/5A3797F3-….bin

The app was launched at 2026-08-15 15:30:02 — nineteen months later. Afterwards `inbox/`
held nothing but its empty `.staging/`, `blobs/dd…` and `thumbnails/dd…` existed, and the
database read:

    title          created_at                 captured_at                collection
    PhoneShareOne  2025-01-15 00:00:00.000    2025-01-15 00:00:00.000    Unsorted

`created_at` is the capture time and not the drain time, which is the assertion the whole
column change exists for. `AppLog.capture` carried one line: `inbox drain: 1 ingested,
0 retrying, 0 incomplete`.

**The activation pass.** With the app still running, a second record was written
(`capturedAt` 2025-03-01T00:00:00Z). It **stayed in the inbox** — proof that there is no
timer and no watcher. Finder was activated and then the app was, and after that:

    inbox/          (empty but for .staging/)
    PhoneShareTwo  2025-03-01 00:00:00.000    Unsorted
    PhoneShareOne  2025-01-15 00:00:00.000    Unsorted

ordered by `created_at DESC`, newest capture first. The log carried exactly two drain
lines for the whole session, one per pass — no third.

**What was not exercised in the app:** the overlap guard, which needs a pass slow enough
to activate into and is covered by the scheduler's suite instead; and the iOS half of the
loop, which still needs a device pairing that S4b has not reached.

## Verification

Fourteen new tests. No existing assertion was edited; the only changes to existing test
code are two defaulted parameters on the round-trip rig (`capturedAt:` on `seedImage`,
`sort:` on `targetItems`), both behaviour-preserving.

| | |
|---|---|
| `AtelierCore` | **765 / 106** — was 760 / 105 |
| `AtelierCapture` | 93 / 4 — unchanged |
| `AtelierIngestion` | 462 / 47 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| extension | 535 / 535 `node --test`; `drift-check` reports no drift |
| `AtelierRefsTests` | `xcodebuild test`, `platform=macOS` — **TEST SUCCEEDED** |
| iOS Debug | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |
| launch drain, real app | record ingested, `created_at` = `capturedAt`, in Unsorted |
| activation drain, real app | second record ingested only on activation, ordered correctly |

## Files

    AtelierCore/Sources/AtelierCore/             both insert sites take `createdAt` from the
      Services/AppServices.swift                 source draft's `capturedAt` instead of
                                                 `Date()`, with the reasoning stated once
                                                 under `MARK: - Ingest` and pointed at from
                                                 each site
    AtelierRefs/AtelierRefs/                     NEW — the cadence: a launch pass, an
      InboxDrainScheduler.swift                  activation observer, the single-pass guard,
                                                 and the summary → log / refresh mapping.
                                                 Takes the pass as a closure and the
                                                 `NotificationCenter` as a parameter
    AtelierRefs/AtelierRefs/                     `bootstrap()` calls `activateInboxDrain`
      IngestionModel.swift                       after the capture endpoint; new
                                                 `refreshAfterIngest(touching:)` extracted
                                                 from `handleRemoteCapture` and shared by
                                                 both producers; holds the scheduler
    AtelierCore/Tests/AtelierCoreTests/          NEW — +5: `created_at` on both insert
      ServicesCreatedAtTests.swift               paths, across the link canonicalization,
                                                 an out-of-order backlog reading in capture
                                                 order, and a dedup keeping the FIRST
                                                 capture's date
    AtelierRefs/AtelierRefsTests/                NEW — +8: the launch pass, activation,
      InboxDrainSchedulerTests.swift             `start()` idempotence, dormancy before
                                                 `start()`, three activations dropped
                                                 during one pass, the guard releasing
                                                 afterwards, and the refresh firing only on
                                                 `ingested > 0`
    AtelierRefs/AtelierRefsTests/                +1: newest-first ordering survives the
      LibraryArchiveRoundTripTests.swift         round trip, not just manual order;
                                                 `seedImage` gains a defaulted `capturedAt:`
                                                 and `targetItems` a defaulted `sort:`
    .docs/092-ios-companion-plan.md              S3's app-wiring deferral discharged; "Where
                                                 this stands" updated

## Migration notes

**Existing libraries are unaffected.** This changes `created_at` for **newly inserted rows
only**. Nothing is rewritten, no migration runs, and no row already in a library moves. A
library opened after this build looks exactly as it did before, except that captures
inserted from now on carry their capture time.

**Two producers change what they write, and both intentionally.** An inbox drain and an
archive import now stamp `created_at` from the source's `capturedAt` rather than from the
clock. Every other producer — paste, drag, the clipboard watcher, the Chrome extension —
passes `capturedAt: Date()` and is byte-for-byte unchanged. Anything downstream that
treated `created_at` as "when this row was written" was already only accidentally right;
it is now a capture time, which is what the column has always been read as by the UI.

**A library that has both.** An archive imported before this build sits at the import's
timestamp; the same archive imported after sits at its captures' real times. Re-importing
is safe — 18A dedup resolves onto the existing assets — but it will **not** re-date them,
because a dedup reuses the row it found rather than writing a new one. Fixing an old
import's ordering therefore means a fresh library, and that is a deliberate limit rather
than an oversight: nothing rewrites history here.

**`InboxDrainScheduler.start()` is idempotent.** It subscribes once and drains once; a
second call is a no-op rather than a second subscription. A future re-bootstrap path can
call it without inheriting a scheduler that drains twice per activation for the rest of
the app's life.
