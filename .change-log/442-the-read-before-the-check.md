# 442 — the read before the check

`InboxDrain.drainOnce()` documents a contract:

> Cancelling the surrounding task stops the loop between chunks and leaves everything not
> yet resolved untouched. An unfinished pass under-reports rather than mis-reports, and the
> inbox itself is the accounting that survives.

It held everywhere except the one stretch where a pass spends the most time before it can
report anything.

`orderedEntries(of:)` reads and decodes **every** pending record before the first one runs.
That is required by [405](405-the-order-a-uuid-sorts-in.md)'s capture-time ordering and the
trade is argued correctly there — `capturedAt` lives inside the record, so there is no
cheaper way to sort by it. But the cancellation check sat *inside* the loop that consumes
the result:

```swift
for entry in orderedEntries(of: pending) {
    if Task.isCancelled { return pass.summary }
```

Swift evaluates the sequence expression first. So a fifty-record backlog did fifty file
reads and fifty JSON decodes, and only then asked whether anyone still wanted the answer.
Quit the app in that window and the pass had done all of it and returned nothing.

## What this is and is not

It is not a correctness bug. Nothing is touched during the read — no record is resolved, no
attempt spent, no file moved — so an interrupted read already left the inbox exactly as it
found it. The contract's *outcome* was always right.

What was wrong is narrower and worth one line anyway: the pass under-reported having spent
the time regardless. On a small inbox that is invisible. On the backlog the ordering exists
to serve — a phone that captured all afternoon, opened on the Mac once — it is the longest
uninterruptible stretch in the pass, sitting on the app-activation path.

## The check is asked twice

Once before the read, once after it. The second is the one that pays, since the read is
where the time goes; the first is free and makes the intent legible rather than looking
like a stray guard.

Deliberately not pushed *into* `orderedEntries`. That function is a pure read-and-sort with
one job, and threading cancellation through it would either make it return an optional or
have it swallow a decision that belongs to the pass. Two lines at the call site say the same
thing where the caller can see them.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/InboxDrain.swift` — the entries are bound
  to a local, with a `Task.isCancelled` check either side of the read.

## Verification

`swift build` clean. `swift test --filter InboxDrain` → 32 tests in 1 suite, all passing,
including `cancelling mid-pass leaves every record it had not reached untouched` and the
live writer/drain race case.

No new test. The existing cancellation coverage asserts the property that matters — an
interrupted pass touches nothing — and it held before this change as well as after; what
changed is when the pass notices, which is a latency fact rather than a behavioural one and
would need a decode-timing seam to assert. Not worth a seam.

## Migration notes

None.
