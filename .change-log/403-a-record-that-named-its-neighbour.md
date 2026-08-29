# 403 — a record that named its neighbour

A capture in the inbox could delete the capture beside it. Not by escaping the
directory — that was closed in [395](395-the-record-is-the-commit-marker.md) and is
still closed — but by staying inside it and pointing at a file that was never its own.
This is **R1**, the first slice out of the review pass over
[092](../.docs/092-ios-companion-plan.md) · S2/S3, and it closes three findings in the
`AtelierCapture` layout/writer pair: one that loses data, one that loses the reason a
share failed, and one that teaches the next reader the wrong habit.

## A `payloadFile` may name one file, and it is the record's own

`InboxRecord.payloadFile` is a string that crossed a process boundary, so the layout
treated it as data and asked one question of it: is this a single, non-relative path
component? That question refuses `../../etc/passwd` and `nested/a.bin`, and it is the
right question for a name with nothing to check it against. It is far too weak for a
name that arrived attached to an id.

`<other-uuid>.json` is a plain component. So is `<other-uuid>.bin`, and `failed`, and
`.staging`. A record naming any of them resolved, passed `isComplete` because the file
really is there, and was handed to the pipeline as media. Then the drain resolved the
same name a second time to finish with the record — and the second resolution is the
one that bites. On the success path `InboxDrain.discard` **deletes** what
`payloadURL(for:)` returns; on the failure path `quarantine` **moves it into
`failed/`**. Either way a healthy neighbouring capture is gone, and the share the user
watched succeed is not in the library and never will be. A record naming `failed`
would have taken the whole quarantine directory.

A `payloadFile` is now valid only when it equals `InboxLayout.payloadFileName(for:)`
of the record's own id — the exact string the writer produces, asked through the
writer's own function so the check and the thing it checks cannot drift. The test is
no longer "could this be appended to a directory" but "is this the name we would have
written", which is a property the inbox actually has. Everything else resolves to
nothing, and the drain quarantines it on sight with `attempts` unspent — the existing
rule for a refused name, because no amount of retrying makes a wrong name right.

The check lives in `InboxLayout`, on `payloadURL(for record:)`, and `isComplete` now
goes through that accessor rather than asking the weaker question itself. So there is
exactly one place that decides whether a record's payload resolves, and the three
consumers — completeness, ingest, quarantine — cannot disagree about it. The
plain-component guard stays exactly where it is still the right question: `failedURL`,
and the sidecar name `quarantineUnparsedRecord` GUESSES for a `.json` that would not
parse, which by definition has no record to be checked against.

One deliberate consequence: `quarantine` resolves the payload through the record
rather than through the bare name it carries. A record being quarantined *because* its
`payloadFile` was refused must not have that name honoured on the way out, or
quarantine becomes the thing that carries off the sibling.

## The writer knew why, and threw it away

Every `catch` in `InboxWriter` caught an error, dropped it, and substituted a typed
case carrying a path. `payloadWriteFailed(path:)` is what a full disk produces. It is
also what a data-protection denial on a locked device produces, and a container that
is not mounted, and a permissions problem — four different fixes behind one identical
string.

That is survivable in a process you can attach a debugger to. This one is a share
extension: no debugger, no test host, one error card that collapses all six typed
failures into "that one didn't save" (093 § 1), and a single `logger.error` line that
was printing `String(describing: error)` at a point where the cause no longer existed.

Each case now carries an `underlying: String` beside its existing payload, rendered
once by `InboxWriteError.describing(_:)` so the four sites cannot each invent a format:
the `localizedDescription` sentence a human reads, plus the bridged domain and code a
search engine and `errno` understand — `NSCocoaErrorDomain 640`, `NSPOSIXErrorDomain
28`. A `String` and not a boxed `any Error`, because the enum is `Equatable` precisely
so tests can assert a case, and a boxed error would cost that.

`underlying` is a thing to read and never a thing to branch on or assert equal, so the
tests do not pin it. They compare an `InboxWriteError.Shape` — the case and its path,
which is the contract — and separately assert the reason is populated. That is a small
test-only helper rather than a pattern-match repeated at four sites, and it is the
reason the four failure tests still read as one line of intent each.

## Two ways to compose one path

`quarantine` asked the guarded `layout.failedURL(named:)` for the payload's
destination and then hand-built the record's on the next line;
`quarantineUnparsedRecord` hand-built again. Neither was unsafe — both names are
generated or enumerated. That is exactly why it was worth fixing: a guarded call and a
hand-built path in the same breath tells the next reader that either is fine, and the
next path composed by hand will be built from a name that came off disk.

`InboxLayout.failedRecordURL(for:)` now mirrors `recordURL(for:)` / `payloadURL(for:)`,
and the drain composes nothing. The unparsed-record site uses `failedURL(named:)`
rather than `failedRecordURL(for:)` — there is no record there to take an id from, and
a `.json` whose stem is not a uuid must keep the name it was enumerated under rather
than be renamed into a shape it may never have had. Both destinations come from the
layout, which is the property the finding was about.

## What the tests now hold

The load-bearing one is in `InboxDrainTests` and it is about a file that is not being
tested: a hostile record naming a victim's `.json`, drained alongside the victim, and
the assertion is that **the victim is still in the inbox afterwards** — still
enumerable, still at `attempts: 0`, and not in `failed/` either. The victim is
deliberately an incomplete capture so that it survives the pass regardless of which of
the two records the enumeration reaches first.

The rest sit in `AtelierCaptureTests`: a sibling's `.json` and its `.bin` both refused
while the files genuinely exist on disk (so the refusal is a refusal of something that
would otherwise resolve), `.staging` and `failed` refused with both directories present,
the canonical name still resolving and still complete, and `failedRecordURL` composing
into `failed/` beside the sidecar destination the guarded accessor produces.

## Files

    AtelierCapture/Sources/AtelierCapture/       `payloadURL(for record:)` now demands the
      InboxLayout.swift                          canonical name; `isComplete` routed through
                                                 it; new `failedRecordURL(for:)`;
                                                 `payloadURL(named:)` documented as the
                                                 no-record-to-check-against resolver
    AtelierCapture/Sources/AtelierCapture/       every `InboxWriteError` case gains
      InboxWriter.swift                          `underlying: String`, rendered by the new
                                                 `describing(_:)` at all four throw sites
    AtelierCapture/Tests/AtelierCaptureTests/    +4 tests (sibling names, inbox directories,
      InboxWriterTests.swift                     canonical name, `failedRecordURL`); the four
                                                 typed-failure tests now assert `Shape` plus a
                                                 populated reason, through one helper
    AtelierIngestion/Sources/AtelierIngestion/   the `:165` guard and `quarantine`'s payload
      Input/InboxDrain.swift                     both resolve through the record; both
                                                 quarantine destinations come from the layout
    AtelierIngestion/Tests/                      +1 test: the sibling survives
      AtelierIngestionTests/InboxDrainTests.swift
    AtelierRefs/AtelierRefsShare/                comment only — the log line is where
      ShareViewController.swift                  `underlying` lands, and the line refs moved
    .docs/092-ios-companion-plan.md              a dated note that the review pass is running

## Verification

| | |
|---|---|
| macOS app | `xcodebuild build`, `platform=macOS` — **BUILD SUCCEEDED** |
| iOS Debug | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |
| `AtelierCapture` for iOS | `swift build --triple arm64-apple-ios26.0` — **Build complete** |
| `AtelierCore` | 760 / 105 — unchanged |
| `AtelierCapture` | **77 / 4** — was 73 / 4 |
| `AtelierIngestion` | **448 / 47** — was 447 / 47, no tie-break flake this run |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |

## Migration notes

None for users. Nothing ships on iOS yet, and no inbox that exists today contains a
record the tightened check would refuse: `InboxWriter` is the only producer, and it can
only ever write the canonical name. A record that IS refused was not written by this
codebase, and the outcome for it is quarantine rather than data loss.

**`InboxWriteError`'s four cases each gained an associated value.** This is
source-breaking for any exhaustive pattern match outside this repo — `case
.payloadWriteFailed(let path)` no longer compiles, and neither does constructing a case
without `underlying:`. Inside the repo the only matches are in the writer itself and in
`InboxWriterTests`; `ShareViewController` renders all six typed errors through one card
and one `String(describing:)`, so it needed no change and now logs strictly more.

The behavioural change to watch on a branch is `InboxLayout.payloadURL(for record:)`
returning `nil` where it used to return a URL. Anything that reads it as "media-less
record" rather than "no payload this record may claim" will now silently treat a
malformed capture as a content capture. The drain does not — it refuses the record
before that question is asked, at `InboxDrain.swift:168` — and any new consumer must
check the name before deciding what a `nil` means.
