# 449 — the phone lets go

[417](417-one-control-that-sends.md) shipped the export with a deliberate property, argued
correctly at the time:

> **Nothing is deleted.** After an export the records stay exactly where they were. Deleting
> would mean trusting that a share sheet the user may have cancelled, an AirDrop that may
> have failed, and an import that may not have happened yet, all succeeded.

Every word of that is right. What it never said is the consequence.

`CaptureExport` reads **all** pending records on every run. Nothing ever leaves `inbox/`.
So export twelve re-sends the two hundred payloads export eleven sent, the App Group
container grows for the life of the device, and the only way to reclaim the space is to
delete the app. There is no UI that even reveals it — the toolbar count says "3" meaning
"three ever", not "three waiting", and a user has no reason to read it the second way.

Correct, and unbounded. Import idempotency made re-sending *free*, and free is not the same
as *bounded*.

## Retirement is the user's assertion

`inbox/sent/` — a plain directory beside `failed/`, skipped by `pendingRecordURLs()` for the
same reason (the enumeration takes top-level `*.json`, and a directory has no extension).
Records and payloads **move** there. Nothing is deleted, and the assertion is reversible by
dragging a file back.

`InboxRetirement.retire(_ ids:in:)` does the moving: payload first, mirroring both the
writer's commit order and the drain's quarantine, so what ends up in `sent/` is a whole
capture rather than a record whose bytes are elsewhere. Record last, so an interrupted pass
leaves the capture **pending** — the recoverable direction. Never throws; a capture that will
not move is counted and stepped over, because this runs behind a button on a phone and a
half-finished tidy-up must not become an error anyone has to understand.

**Why not a receipt from the Mac.** An acknowledgement round-trip is more rigorous and is the
thin end of the two-way sync 091 · D4 spent a paragraph refusing — conflict resolution over
collections, ordering and Spaces geometry. One control the user presses when they have seen
the import land is a complete answer to storage growth and adds no second transport
direction.

## Only what was actually sent

`InboxArchive.Summary` gains `exported: [UUID]`, appended at the one line the loop reaches
only when a capture is genuinely in the manifest.

This is the load-bearing detail. `captures` counts and says nothing about **which**, and the
records handed in are a superset: the funnel refuses some, a payload goes missing, and those
stay pending on purpose. Retiring on the strength of an export a capture was not in is
precisely how "nothing is lost" would stop being true — so `exported` is what the phone
retires, and `exported names only the captures that reached the manifest, never the skipped`
pins it.

A capture made *while the share sheet was open* is excluded by the same mechanism.

## The offer, and why it waits

`ExportSentNotice` appears when the share sheet is dismissed and something reached the
manifest. Two buttons: **Keep** first and plain, **Clear** second.

`UIActivityViewController`'s completion handler cannot distinguish a landed AirDrop from a
cancelled one, and the Mac says nothing back by design. So the app does not infer — it asks,
once, at the only moment the user knows, with the cautious answer requiring no thought.

**No auto-dismiss timer**, unlike the failure notice it sits beside. That one reports
something already true and needs no answer; this one asks a question, and a question that
vanishes after four seconds is a question answered by accident.

The wording avoids "delete", because nothing is deleted.

## Files changed

- `AtelierCapture/Sources/AtelierCapture/InboxLayout.swift` — `sentDirectoryName`, `sent`,
  `sentRecordURL(for:)`, `sentURL(named:)` under the same plain-component guard
  `failedURL(named:)` uses.
- `AtelierCapture/Sources/AtelierCapture/InboxRetirement.swift` — new.
- `AtelierCapture/Tests/…/InboxRetirementTests.swift` — new, 8 tests, fixtures built with the
  real `InboxWriter`.
- `AtelierArchive/…/InboxArchive.swift` — `Summary.exported`.
- `AtelierArchive/Tests/…/InboxArchiveTests.swift` — the skipped-vs-exported test.
- `AtelierRefsMobile/CaptureExport.swift` — `.sent(Int)` phase, `exported` ids, `retire()`,
  `keep()`; `write` returns the folder *and* what is in it.
- `AtelierRefsMobile/ExportControls.swift` — `ExportSentNotice`.
- `AtelierRefsMobile/ContentView.swift` — the overlay branch.

## Verification

`swift test` → AtelierCapture **115** (was 107), AtelierArchive **57** (was 56).
`xcodebuild build -scheme AtelierRefsMobile` → BUILD SUCCEEDED.
`AtelierRefsTests` on macOS → TEST SUCCEEDED, `InboxArchiveImportTests` included.

**Not covered by a test, and named rather than implied:** the notice itself. Driving it needs
a share sheet and a simulator, so `ExportSentNotice` and the `.sent` branch are asserted only
by the build. Everything under them — what retires, what does not, what `exported` contains,
what `sent/` hides from — is tested on the host.

## Migration notes

None. An inbox with no `sent/` behaves exactly as before; the directory is created lazily on
the first retirement, so a phone whose user never presses Clear never grows one.
