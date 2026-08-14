# 395 — the record is the commit marker

The third slice of the iOS companion ([092](../.docs/092-ios-companion-plan.md) ·
S2). The share extension's half of the handoff: `InboxRecord`, the file it leaves
behind, and `InboxWriter`, the one method that puts it there.

A share extension runs on a much tighter memory budget than its host — an observed
~120 MB, not a contractual number — and `IngestPipeline` decodes originals and
generates thumbnail tiers, so a 4000px share would put it into jetsam and the user
would watch a share sheet succeed at nothing ([091](../.docs/091-ios-companion-overview.md)
· D2). So the extension does the smallest durable thing: write the bytes, write a
record, return. No SQLite, no decode, no pipeline.

Nothing is wired to this yet. There is no iOS target and no drain; both are later
slices. What exists now is the format and the guarantee.

## The guarantee is an ordering

The writer and the drain are separate processes with no lock between them. Written in
place, a record could be read by the drain between its creation and its last byte, or
between the record and the payload it names — and the drain would read those as
*corrupt*, not as *early*. Quarantining a capture that was merely half a second young
is a share the user watched succeed and will never see again.

So the write commits in two phases: stage the payload, move it to `<inbox>/<uuid>.bin`,
then stage the record and move it to `<inbox>/<uuid>.json`. A rename within a volume is
atomic, so each file appears whole or not at all. **The record is the commit marker.**
No record means nothing to drain, whatever loose bytes are lying around; a record means
its payload is already there, because it was moved first.

The one state the ordering does not rule out is a payload with no record, when the
process dies between the phases. That is a leak of bytes, not a corruption — the drain
enumerates `*.json` and never sees it — and it is bounded by best-effort cleanup. The
state that *is* ruled out is a record without its payload, which is the one the drain
cannot tell apart from data loss. When it does see one anyway, after a torn write on a
crash, `InboxLayout.isComplete(_:)` says so and S3 skips the item this pass.

Three tests exist for that ordering alone, the load-bearing one being that a payload
which fails to land leaves no record behind: had the `.json` been written first, it
would be sitting there, naming bytes that never arrived.

## Four decisions that depart from the plan

**The code is in `AtelierCapture`, not `AtelierIngestion`.** 092 put the layout in
`LibraryLayout` and, by implication, the record and writer beside it. That cannot work:
`AtelierIngestion` imports AppKit through `Input/DirectInputReader.swift`, so it does
not build for iOS at all and the share extension could never link it. `AtelierCapture`
is transport-free and platform-free by construction and the extension already links it.

So the dependency arrow reverses. `InboxLayout` owns `directoryName`, `AtelierIngestion`
gains a path dependency on `AtelierCapture`, and `LibraryLayout.inbox` delegates rather
than spelling `"inbox"` a second time. There is still exactly one authority on where the
handoff lives, reachable from both sides of a boundary the extension can only cross one
way. No cycle: AtelierCapture → AtelierCore, AtelierIngestion → AtelierCore +
AtelierCapture.

**Staging is `inbox/.staging/`, not `cache/`.** The plan said `cache/`, but `cache` is a
name `LibraryLayout` owns, and the whole point of the previous decision is that
`AtelierCapture` does not learn the library's directory structure — learning a second
directory name in order to write one file would undo it. `inbox/.staging/` is on the
same volume as its destination, which is the only property an atomic move actually
needs, and it is invisible to the drain: `pendingRecordURLs()` reads the top level of
`inbox/` and takes only `*.json`, so a dot-directory full of in-flight writes is not
something the drain can trip over.

**`InboxRecord` carries `attempts` from the start.** 092 has the drain "stamp an attempt
count into the record" in S3. Adding it there would mean every record written by an
already-shipped extension predates the field, and the host would have to tolerate its
absence forever anyway. Cheaper to define it now, default it to 0, and let the drain be
the only thing that increments it. The decode tolerates a missing `attempts` regardless
— one line, and this is a format on disk read across two independently shipped binaries.

The same reasoning pinned the coders. `InboxRecord.makeEncoder()` sets
`.secondsSince1970` explicitly, because the default `.deferredToDate` means "seconds
since the *reference* date", a Foundation implementation detail that would be a bad
thing to have baked into a file two separate binaries read; and `.sortedKeys`, so a
record's bytes are a function of its values.

**`CaptureRequest.image` is nil on this path**, and the writer enforces it — but only
halfway, deliberately. When bytes went to the sidecar, the base64 field is dropped:
carrying both would double the record and put a base64 string of an image in memory in
whichever process parses it, which is precisely what the sidecar exists to prevent. When
there are no bytes, an `image` is left alone, because it is still a valid capture the
existing decode funnel understands and silently dropping it would lose the share rather
than shrink it. The field stays on `CaptureRequest` for the HTTP producer, which is
bounded by the server's body cap and has no file to write to.

## One thing 092 did not ask for

`InboxLayout.payloadURL(named:)` refuses any `payloadFile` that is not a single plain
path component, and returns nil rather than a URL. That string arrives inside a file
written by another process; resolving `"../../"` against the inbox would be a path the
drain then reads and deletes. It is four cheap conditions, and the failure mode it
closes is not one that would show up in a test that did not go looking.

## The GRDB claim in 389 was wrong

[389](389-one-contract-two-producers.md) says `AtelierCapture`'s boundary is what lets a
memory-capped share extension "link it without dragging GRDB along". That is false as
built. `AtelierCore/Package.swift:31` depends on GRDB, and `AtelierCapture` depends on
`AtelierCore` for `SourceDraft` / `Platform` / `AssetContentDraft`, so GRDB is on the
extension's link line transitively. Everything else in that paragraph holds — no
FlyingFox, no sockets, no AppKit, no filesystem — but the GRDB half does not, and no
reachable change to `AtelierCapture` would make it true.

This is accepted, not fixed. GRDB is linked and never instantiated: the extension opens
no `DatabasePool` and no connection, and the ~120 MB ceiling is about dirty memory,
where linked code pages are not dirty. Removing it would mean splitting the domain types
out of `AtelierCore`, a far larger refactor than the number justifies.

What changes is the check. 092 · S4 said "if the extension's link line ever grows GRDB,
D2 has been violated; make that a review check, not a hope" — an assertion that is
already false and would have failed a review of code that is fine. It now asks for a
measurement of the extension's actual footprint against the ceiling, and keeps the real
invariant, which is a behaviour: the extension never *opens* a database and never
decodes an image. 389 carries a dated correction note rather than a rewrite.

## Files

    AtelierCapture/Sources/AtelierCapture/InboxLayout.swift
                                                        new — directory names, path
                                                        math, and the two questions
                                                        that need the disk
    AtelierCapture/Sources/AtelierCapture/InboxRecord.swift
                                                        new — the on-disk format,
                                                        pinned coders, tolerant decode
    AtelierCapture/Sources/AtelierCapture/InboxWriter.swift
                                                        new — the two-phase write and
                                                        `InboxWriteError`
    AtelierCapture/Sources/AtelierCaptureTestSupport/CaptureFixtures.swift
                                                        `sampleContent(kind:…)` — the
                                                        media-less builder, shared
    AtelierCapture/Tests/AtelierCaptureTests/InboxWriterTests.swift
                                                        new — 15 tests
    AtelierIngestion/Package.swift                      AtelierCapture path dependency
    AtelierIngestion/Sources/AtelierIngestion/Media/LibraryLayout.swift
                                                        `inbox`, delegating to
                                                        `InboxLayout.directoryName`
    AtelierIngestion/Tests/AtelierIngestionTests/LibraryLayoutTests.swift
                                                        new — 4 tests
    .change-log/389-one-contract-two-producers.md        dated GRDB correction
    .docs/092-ios-companion-plan.md                      S2 "As built"; S4's link-line
                                                        check becomes a measurement;
                                                        the platform-pin blocker

`AtelierCapture` 23 tests in 1 suite → 38 in 2. `AtelierIngestion` 441 in 46 → 445 in
47. `AtelierServer` 62 in 6, unchanged. All passing; the app's `xcodebuild build`
succeeds.

The three new sources were type-checked against the iPhoneOS SDK directly
(`swiftc -typecheck -target arm64-apple-ios26.0 -swift-version 6`, with the capture
contract stubbed, which passes) because a real iOS build cannot run yet: `swift build
--triple arm64-apple-ios26.0` fails with *"`AtelierCore` requires ios 12.0, but depends
on `GRDB` which requires ios 13.0"* — no package declares an `.iOS(...)` platform, so
they all default to iOS 12. That is the deployment-target audit S4 already owns, now
with a concrete first symptom, and it was left alone here rather than pulled forward to
satisfy a verification step.

## Migration notes

None for users. Nothing reads or writes the inbox yet; `LibraryLayout.inbox` is path
math over a directory that no code creates, and no stored shape, wire shape or endpoint
changed.

For the build: `AtelierIngestion` has a new local path dependency on `AtelierCapture`,
so a clean checkout resolves one more package there. Xcode needed no `project.pbxproj`
change — `AtelierCapture` was already in the graph through `AtelierServer`, exactly as
389 found — and `AtelierIngestion` sources now `import AtelierCapture` where they touch
the inbox, which is one file.
