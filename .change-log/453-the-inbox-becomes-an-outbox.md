# 453 — the inbox becomes an outbox

`InboxDrain` has always ended a capture's life the same way:

> The record and its payload are removed only after the coordinator has reported
> `.ingested`.

The record's absence *is* the commit marker. That is correct on the Mac, where the library a
capture drains into is the library the user was aiming at — and it rests on an assumption
nobody had to name, because until now only one host ever drained anything.

The phone is about to. [452](452-the-factories-were-never-the-appkit-part.md) made
`AtelierIngestion` build for iOS; the next phase wires the drain into the companion app so a
share appears in the phone's own grid instead of sitting invisibly in `inbox/` until a Mac is
opened. And on the phone that same ingest is **half of the trip**. `InboxArchive` sends
captures to the Mac by reading the inbox, because the phone's SQLite library holds only what
has been synced back to it — so a drain that deleted the record there would destroy the only
copy the export has. Draining the inbox would silently stop the phone from ever exporting
again.

Nothing here is wired into the iOS app. This phase makes the record survive ingestion, on
the host, under `swift test`.

## `inbox/ingested/`, and why not `sent/`

A fourth directory beside `.staging/`, `failed/` and `sent/`. A successfully ingested record
and its payload **move** there, which takes them out of `pendingRecordURLs()` — so no later
pass drains the same capture again — without taking them off disk.

`sent/` was the obvious thing to reuse and is the wrong answer. That directory means *the
user asserted this reached the Mac*; these captures have asserted nothing and are exactly the
ones still waiting to go. Folding them together would make the next export skip a capture the
phone had never sent.

The invisibility is the same argument the other three make — the enumeration takes top-level
`*.json`, and a directory has no extension — and it is now relied on four times, so it has a
test rather than only a paragraph. `ingestedRecordURLs()` is a **second** enumeration rather
than a flag on the first: the drain asks "what is pending" and must keep getting the old
answer, and only the export wants the union.

## A stated policy, not a platform check

`InboxDrain.Retention` — `.discardWhenIngested` or `.retainForExport` — with **no default**.
A default would be a decision about who owns the library at the end of the drain, taken
silently on behalf of every future caller, and the caller that gets it wrong loses captures
rather than failing a build. `IngestionModel` now says `.discardWhenIngested` out loud, which
is exactly what it did before.

Not `#if os(iOS)`, and that is the point: both behaviours are exercised by `swift test` on
macOS, including the half that is new. A platform check would have made the phone's path
testable only on a phone.

Spelled as a policy rather than a `Bool` because the call site is the only place the
reasoning is visible, and `keepRecords: true` is a fact with its argument removed.

## The record moves first — leak beats wedge

The inbox encodes two facts: **pending**, which is the record sitting where
`pendingRecordURLs()` looks, and **complete**, which is the payload sitting beside it
(`isComplete`).

Move the payload first and an interruption leaves a record that is still pending and no
longer complete. `isComplete` returning false means one specific thing to the next pass — *the
writer is mid-flight, come back later* — and that answer never changes here, because there is
no writer. The capture is skipped as incomplete on every pass for the life of the device and
the pending count never comes down. **A wedge.**

Move the record first and an interruption leaves an ingested record whose bytes are still in
the inbox top level. Nothing is confused: the enumeration takes only `*.json`, so a stray
`.bin` is invisible to every pass, and the export resolves a payload from either site
precisely so this state reads as a whole capture. `InboxRetirement` reclaims the stray when
the capture is cleared. **A leak.**

This is the same trade `discard(_:)` already takes, the inverse of `InboxWriter`'s commit
order, and the *opposite* conclusion from `quarantine`, which moves the payload first because
nothing reads `failed/` again and a whole capture is what a human digging in there needs.

If the record will not move, the payload is deliberately left where it is — moving it anyway
would manufacture exactly the wedge above. The capture stays pending, the next pass re-ingests
it, and 18A blob-hash dedup resolves that onto the asset already in the library. That is the
same cost as crashing mid-drain, which this design accepted long ago.

## Export reads both sets

`InboxArchive.pendingRecords(in:)` now reads the pending set **and** the ingested one, and
`payloadSite(of:layout:)` finds a payload at either location, inbox first (so a half-finished
retention reads as the whole capture it is).

The name stays `pendingRecords`. "Pending" here has always meant pending **export**, and
until the phone drained its own inbox the two sets were the same one. The doc comment now
says so instead of leaving it to be inferred.

Ids are deduplicated, keeping the first of a repeat. Retention *moves* a record, so a record
in both places is not a state the drain can produce — the guard is against a half-finished
hand-edit of an inbox producing a manifest with two entries under one source id, which the
reader has no way to make sense of.

**Why the two-site lookup lives in `InboxArchive` and not in `InboxLayout`.** A layout method
meaning "wherever the payload is" would have been the tidier-looking place for it, and would
have put that answer within reach of the drain — which must read exactly one site, or it
re-runs captures it has already run.

## Clear deletes what the library already holds

[449](449-the-phone-lets-go.md) built retirement on "nothing is deleted", and that was the
right guarantee when `sent/` was the only thing standing between a capture and oblivion. For
an ingested record it no longer is: the phone's library holds the asset and its blob, so
*nothing is lost* is guaranteed by that copy. Keeping a second one under `sent/` would defer
the unbounded growth 449 was written to end rather than ending it.

So `InboxRetirement` **deletes** an ingested record and its payload, and moves a pending one
to `sent/` exactly as before. `sent/` is not a fallback and is not dead code: a phone whose
drain has never run — every phone until Phase 3 — retires records that were never ingested.

Which fate applies is read off the disk, not passed in: the caller is a button, and it knows
what the user asserted rather than which directory the drain left a capture in. The deletion
takes the record first for the reason above, one level worse: a record with no bytes is not
merely a leak, it is a capture every future export reads, refuses and reports as skipped —
offered forever, sendable never.

Clearing an ingested capture also reclaims a stray `inbox/<uuid>.bin` — the residue of an
interrupted retention. Nothing enumerates a bare `.bin`, so this is the one moment in the
program that can reclaim it, and only when no pending record is left to own the name.

`Summary.retired` counts both fates under one number. What a caller does with it is tell the
user how many captures left the waiting set; moved-versus-deleted is a fact about which
directory the phone had them in, not about anything the user asked for.

## Files changed

- `AtelierCapture/Sources/AtelierCapture/InboxLayout.swift` — `ingestedDirectoryName`,
  `ingested`, `ingestedRecordURL(for:)`, `ingestedURL(named:)` under the same
  plain-component guard `failedURL(named:)` and `sentURL(named:)` use; `ingestedRecordURLs()`
  beside `pendingRecordURLs()`, both now one private enumeration so their filters cannot
  drift.
- `AtelierCapture/Sources/AtelierCapture/InboxRetirement.swift` — two fates; `moveToSent`,
  `delete`, `remove`.
- `AtelierIngestion/Sources/AtelierIngestion/Input/InboxDrain.swift` — `Retention`, a
  required initializer parameter, `settle` / `retain`, a lazily-created `ingested/`, and
  `move` now reports whether it worked.
- `AtelierArchive/Sources/AtelierArchive/InboxArchive.swift` — `pendingRecords(in:)` reads
  both sets and dedups; `payloadSite(of:layout:)`.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — one line: the Mac states
  `.discardWhenIngested`.
- `AtelierCapture/Tests/…/InboxLayoutTests.swift` — new, 8 tests.
- `AtelierCapture/Tests/…/InboxRetirementTests.swift` — 8 tests added.
- `AtelierIngestion/Tests/…/InboxDrainTests.swift` — 9 tests added, and both harness drains
  state their policy.
- `AtelierArchive/Tests/…/InboxArchiveTests.swift` — 8 tests added, `Rig.retain`.

## Verification

`swift test`, before → after:

| package | before | after |
|---|---:|---:|
| AtelierCapture | 117 | **133** |
| AtelierIngestion | 467 | **476** |
| AtelierArchive | 57 | **65** |
| AtelierCore | 771 | **771** |

All passing; nothing dropped.

`swift build --triple arm64-apple-ios26.0` in `AtelierIngestion` → Build complete.
`xcodebuild -scheme AtelierRefs -destination 'platform=macOS'` → BUILD SUCCEEDED.
`xcodebuild -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'` →
BUILD SUCCEEDED.
`xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'` → exit 0, which is what
keeps `InboxArchiveImportTests` — the phone-export-to-Mac-import round trip, and the only
test in the program that runs both ends of `pendingRecords(in:)`'s new union — honest.

**What the tests actually pin, and what they do not.** The interrupted-move states are
*forced*, not raced: `inbox/ingested` is made a regular file so `createDirectory` and every
move into it fail, and the half-moved state is built by hand. That proves the reaction to
those states, which is what the ordering argument claims. It does not prove they are the only
states a real interruption can produce — that would need a kill in the middle of a
`moveItem`, and the file's argument stands on `moveItem` being a rename rather than on a test.

The phone's side of all of this is **not exercised end to end**, because it does not exist
yet: no iOS caller passes `.retainForExport`, and Phase 3 is what wires one. Everything the
phone will depend on — the move, the enumeration, the export union, the deletion — runs on
the host here.

## Migration notes

`InboxDrain`'s initializers gain a **required** `retention:` argument. There is one caller in
the app and one harness in the tests; both now state their policy.

An inbox with no `ingested/` behaves exactly as before, and a Mac never grows one — the
directory is created lazily, on the first retained record, under `.retainForExport` only.
There is nothing to migrate on disk in either direction: a capture in `ingested/` is a record
and a payload in the shape `InboxWriter` wrote them.
