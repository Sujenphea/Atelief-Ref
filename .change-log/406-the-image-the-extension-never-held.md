# 406 — the image the extension never held

The share extension's whole argument for itself is that it does not decode pictures. Its
header says so, [092](../.docs/092-ios-companion-plan.md) · S2 says so, and
[091](../.docs/091-ios-companion-overview.md) · D2 names the failure it is avoiding: an
extension jetsammed mid-write is a share sheet that silently did nothing, which the user
cannot tell apart from success. And then `loadDataRepresentation` handed the process the
entire file as a `Data`, which travelled through `SharedItem` and `ShareCaptureDraft`
into `InboxWriter` and only reached disk at the very end — peak footprint one whole
image, resident, in a process with an observed ~120 MB ceiling, with **no size cap
anywhere on the path**. S3 prefers `ByteSource.fileURL` over `.data` at the far end of
the same pipe for exactly this reason. This file was the one place contradicting it.

This is **R4**, two findings from the review pass over S4b-ii. The second is smaller and
older: `harvest` held four decisions in a target with no test host, and three of them
never needed one.

## The bytes are a file now, and the copy happens where it must

`NSItemProvider.loadFileRepresentation` hands over a temporary file instead of a `Data`.
The file is copied into `.staging/` by `FileManager.copyItem`, which streams through the
kernel a buffer at a time and clones the extent map outright within an APFS volume, so a
40 MB share costs this process no more memory than a 40 KB one. Nothing between the
provider and the sidecar ever holds the image.

**The temporary file dies when the completion handler returns**, and getting that wrong
is the whole trap. A handler that resumes its continuation with the URL and copies later
works perfectly on a 200 KB PNG and races on a 40 MB one — the exact bug being fixed,
hidden behind a passing test. So `ShareViewController.adopt(_:)` runs *inside* the
handler, synchronously, before `continuation.resume`, and what the continuation carries
back is a URL in this process's own `temporaryDirectory` that nothing else can delete.
The adopted copy is removed by a `defer` in `capture()` once the capture is committed or
lost.

That is two copies of the file — provider temp → extension temp → `.staging/` → inbox —
where a cleverer arrangement would have one. The alternative was for the writer to hand
out a staging slot, or to take a delivery closure and be *called from inside* the
provider's completion handler; both mean performing a two-phase inbox write on an
arbitrary queue in the middle of a callback, while a second provider's URL is still
outstanding and the card still has to be updated on the main actor. Both copies are
disk-to-disk and both are clones on APFS. Memory was the problem, and neither copy is
memory.

**A copy and never a move**, on both hops. The URL a provider hands over may be storage
another process owns — the sidecar written in the simulator run below came back carrying
Photos' own `com.apple.assetsd.*` extended attributes, including
`originalFilename: share-source.png` — and a mover would be reaching into the user's
photo library.

**`.data` stays, as the fallback it was always going to need.** Not every provider vends
a file representation. `loadImage` asks for a file, logs when there is none, and falls
back; a copy that fails for any reason other than the cap also falls back, rather than
losing the share outright.

## One case for the bytes, one method that differs

`SharedItem.image` used to carry a `Data`. It now carries a `PayloadSource` — `.data(Data)`
or `.fileURL(URL)` — and so does `ShareCaptureDraft.payload`. One case carrying a source
rather than two cases on `SharedItem`, because the provenance, the title, the platform
mapping and the whole draft construction are identical either way: two cases would have
duplicated that branch to express a difference that exists only in the last ten lines of
the write. `SharedItem` stays `Equatable`, `Sendable` and Cocoa-free — `URL` is
Foundation — so it still tests on macOS with no device.

The case names deliberately mirror `AtelierIngestion.ByteSource`. They are two types
because the packages are two link lines (`AtelierIngestion` imports AppKit and cannot
build for iOS at all) and one shared name would need qualifying in the Mac app that
imports both. What actually travels between them is the sidecar on disk, which a
`.fileURL` write produces and a `ByteSource.fileURL` read consumes — nobody's memory on
either side.

`InboxWriter` gained a second `write` overload taking `PayloadSource?`; the `Data?` one
is untouched and now delegates. **The two-phase commit is not duplicated.** They differ
in exactly one method, `stage(_:at:)`, which either writes the `Data` it is holding or
copies the file. The cap, the ordering, the record encode, the commit and the
failure-cleanup are the same code for both, because an ordering that held on one path
and not the other would be worse than not having one. The `PayloadSource` overload
deliberately has no default for `payload`: omitting the argument has to keep meaning
exactly one thing, and "no payload" is already spelled `write(request)`.

## The cap, and what it looks like from the outside

`InboxWriter.maximumPayloadBytes` is **64 MiB**, and it is **a tunable, not a contract**
— one `static let`, so raising it is one edit the first time somebody hits it with a real
share.

Why that number. It has to sit above every share a person actually takes and below the
point where the in-memory fallback threatens the ~120 MB ceiling. A phone photo is 2–5 MB
of HEIC, a full-screen PNG screenshot around 10 MB, a 48 MP ProRAW DNG roughly 25 MB, and
a stitched panorama the largest thing Photos will hand over, at some tens of MB. 64 MiB
clears all of those and is still barely half the ceiling, so even a `.data` payload at the
limit cannot be what kills the process.

It is checked **before anything is copied** — `resourceValues(forKeys: [.fileSizeKey])`
on the provider's temp file, inside the same completion handler, and again in the writer
before it stages — against one constant, through one `payloadSize(of:)` that measures a
`Data`'s `count` and a file's size the same way. A file whose size cannot be read is
deliberately *not* refused: a file that cannot be stat'd is almost certainly one that
cannot be copied either, and the copy's own failure carries what the filesystem said,
where a size refusal would report the wrong problem.

The refusal is a fifth `InboxWriteError`, `payloadTooLarge(bytes:limit:)`, and it is
**the one case with no `underlying`**. [403](403-a-record-that-named-its-neighbour.md)
added that field to the other four because a typed case alone cannot distinguish a full
disk from a data-protection denial. Nothing was caught here — the writer decided this,
and `bytes` and `limit` say everything there is to say. A field holding a sentence this
enum invented would be the opposite of what 403 added it for.

**What an over-cap share looks like to the user:** the existing failure card, in
`warning`, which does not auto-dismiss — *"Couldn't save. Try sharing again."* It was
driven on a simulator (below) and it renders exactly as designed. It is also the one
place this slice found 093 slightly wrong, and that is noted there rather than quietly
reworded: for every other failure the card collapses, re-sharing is a legitimate retry;
for this one it is guaranteed to fail identically. The card is still right to be one
card — this is a lost capture that leaves nothing partial, like the rest — but the
sentence promises something this case cannot deliver. Left as an open question for the
person holding the phone, not changed on a hunch.

## `harvest` no longer decides anything

The second finding. `harvest` held four decisions in a target with no test host: image
bytes beat a URL, the URL then becomes the image's `sourceURL`, a `file://` attachment is
not provenance, and an empty title is no title. None of the four needs a device, and
none of them could be tested where they were.

They are now `ShareCapture.sharedItem(image:urlString:title:)` and
`ShareCapture.webURLString(_:)`, pure over three optionals, tested on macOS under
`swift test`. This is the split S4b-ii already chose, applied to the decisions that had
leaked past it — no new mechanism, and **no iOS test target**, which the user deferred.
What stayed in the controller is the `UTType` conformance check, which genuinely needs
UIKit, and the item-provider loading, which is asynchronous and Cocoa.

The `file://` filter is why any of this matters: `public.file-url` conforms to
`public.url`, so an image shared out of Files arrives with a `file://` attachment on the
same code path a web URL does, and storing it as `originalURL` would put a path from a
container that no longer exists into a capture's provenance.

**One subtlety that is not redundancy.** `webURLString` is applied at the assignment
inside the loop as well as inside `sharedItem`. Moving the filter to the end alone would
have been a regression: a `file://` from one provider would occupy the slot a later
provider's web URL should fill, and the share would lose a URL the old code found. It is
idempotent, so asking twice costs nothing, and asking once in the wrong place costs a URL.

Two smaller consequences, stated rather than slipped in. `ShareCapture.isWebScheme` is now
the single authority on the accepted schemes, asked by both the filter and the platform
mapping — they ask it differently on purpose, since the mapping must still accept a
scheme-less `x.com/i/1` that `canonicalURL` repairs and a shared `URL` always has a
scheme. And **title normalization widened**: `provenance` used to drop only an exactly
empty title, and `normalizedTitle` now also drops a whitespace-only one and trims the
rest, so a title arriving with a trailing newline is the same title. No existing test
pinned the old behaviour; it is a deliberate widening, not an accident.

## What ran on a simulator, and what did not

A build is not evidence. All three cases were driven through the **real share sheet** on
a booted iPhone 17 Pro (iOS 26.5) with the Debug build installed, which resolves
`group.sujenphea.AtelierRefs.dev`. The App Group container needs a signed build —
`CODE_SIGNING_ALLOWED=NO` produces an app with empty entitlements, no container, and a
share that cannot work, which is worth knowing before spending an hour on it.

**An image, through the file path.** A 2400×1600 PNG (1,099,126 bytes) added with
`simctl addmedia`, opened in Photos, shared to the extension:

    AE73BF0B-4738-4D92-9963-8FBC1A1D92C5.json   { "payloadFile": "AE73BF0B-….bin",
                                                  "provenance": { "platform": "web",
                                                    "rawMetadata": { "capturedVia": "ios_share" } } }
    AE73BF0B-4738-4D92-9963-8FBC1A1D92C5.bin    1,099,126 bytes
                                                md5 1eafc91e7a9bd56968b37cfcfbd28ee4
                                                — identical to the source file

`.staging/` empty afterwards. Two independent proofs that the **file** path ran and not
the `Data` fallback: the extension's own log carries the `captured …` line with no
preceding "no file representation", and the sidecar arrived carrying Photos'
`com.apple.assetsd.*` extended attributes — including `originalFilename: share-source.png`
— which `copyItem` preserves and `Data.write(to:)` could not possibly have produced.

**A link, through the moved filter.** Safari on `https://www.pinterest.com/` → ⋯ → Share
→ AtelierRefsMobile wrote a media-less record with `kind: "link"`,
`platform: "pinterest"`, `originalURL` verbatim, no `payloadFile` and no `image`. The
scheme filter and `sharedItem` now run in `AtelierCapture` and this is them running in
the extension's process on a URL Safari supplied.

**An over-cap share, refused.** An 86,933,173-byte PNG (5000×5000 of noise, ~82 MiB)
through the same Photos flow. The failure card appeared and stayed; nothing was written;
`.staging/` empty; and the extension's log says exactly what happened:

    share of 86933173 bytes exceeds the 67108864 byte cap
    capture failed: payloadTooLarge(bytes: 86933173, limit: 67108864)

The first line is emitted from inside the completion handler, before the copy — which is
the property the whole design turns on, observed rather than assumed.

**What was not exercised.** The `.data` fallback on a device: every provider in this run
offered a file representation, which is the good outcome and means the fallback is
covered only by the writer's test matrix. The other five typed failures still need a
broken container, which a simulator does not offer on demand. And **the ~120 MB footprint
measurement is still not done** — it is a 092 gate of its own and wants Instruments, not
a share sheet; this slice removes the largest known contributor to it without measuring
the result.

The automation was as miserable as [402](402-a-share-becomes-a-record.md) recorded, in
the same two ways, and 402's recovery is correct: the Simulator's accessibility window
vanishes from the tree (every tap then reports "no device view found", and only
`killall com.apple.CoreSimulator.CoreSimulatorService` plus a fresh boot brings it back),
and an inactive Simulator window swallows the first click. All three captures above were
taken inside the few minutes of working input that follow a service restart.

## Verification

Twenty-three new tests. Six existing `ShareCaptureTests` call sites changed from
`.image(bytes: png)` to `.image(bytes: .data(png))` and one `#expect(draft.payload == bytes)`
to `== .data(bytes)` — a type change following `SharedItem`, not a weakened assertion.
`InboxWriteError.Shape` gained its fifth case. No existing assertion was edited.

| | |
|---|---|
| `AtelierCapture` | **93 / 4** — was 77 / 4 |
| `AtelierCore` | 760 / 105 — unchanged |
| `AtelierIngestion` | 462 / 47 — unchanged |
| `AtelierServer` | 62 / 6 — unchanged |
| `CanvasRenderer` | 437 / 52 — unchanged |
| `AtelierExport` | 84 / 7 — unchanged |
| extension | 535 / 535 `node --test`; `drift-check` reports no drift |
| macOS app | `xcodebuild build`, `platform=macOS` — **BUILD SUCCEEDED** |
| iOS Debug | `xcodebuild build`, `generic/platform=iOS Simulator` — **BUILD SUCCEEDED** |
| `AtelierCapture` for iOS | `swift build --triple arm64-apple-ios26.0` — **Build complete** |
| image share, real share sheet | record + sidecar, md5-identical, `.staging/` empty |
| link share, real share sheet | media-less `link`, `platform: "pinterest"` |
| over-cap share, real share sheet | failure card, nothing written, `payloadTooLarge` logged |

The cap tests use `FileHandle.truncate` to make a sparse file that *reports* 64 MiB
without occupying it, so the boundary — inclusive at the limit, refused one byte over —
costs the suite no disk and no wait.

## Files

    AtelierCapture/Sources/AtelierCapture/       new `PayloadSource` (`.data` / `.fileURL`);
      InboxWriter.swift                          `maximumPayloadBytes` = 64 MiB and
                                                 `payloadSize(of:)`; a second `write`
                                                 overload taking a `PayloadSource?`, with
                                                 the `Data?` one delegating; the payload
                                                 phase now calls `stage(_:at:)`, the ONE
                                                 method the two paths differ in; fifth
                                                 `InboxWriteError` case `payloadTooLarge`,
                                                 the only one with no `underlying`
    AtelierCapture/Sources/AtelierCapture/       `SharedItem.image` and
      ShareCapture.swift                         `ShareCaptureDraft.payload` carry a
                                                 `PayloadSource`; new `webURLString(_:)`,
                                                 `sharedItem(image:urlString:title:)`,
                                                 `isWebScheme(_:)` and `normalizedTitle(_:)`
                                                 — `harvest`'s decisions, made testable
    AtelierRefs/AtelierRefsShare/                `loadFileRepresentation` preferred, with
      ShareViewController.swift                  `adopt(_:)` copying INSIDE the completion
                                                 handler and `discardAdoptedFile` cleaning
                                                 up; `loadData` demoted to fallback;
                                                 `loadWebURL` → `loadURL`, filter moved out;
                                                 `harvest` throws and decides nothing;
                                                 `logger` is `static`
    AtelierCapture/Tests/AtelierCaptureTests/    +14: the file-source round trip, the two
      InboxWriterTests.swift                     paths agreeing byte for byte, a missing
                                                 file failing as a write, the cap over/at
                                                 the boundary on both shapes, and
                                                 `payloadSize`; `Shape` gains a fifth case
    AtelierCapture/Tests/AtelierCaptureTests/    +9: the web-URL filter (16 rejected shapes,
      ShareCaptureTests.swift                    4 accepted), image-beats-URL on both
                                                 payload shapes, URL-as-sourceURL,
                                                 `file://` dropped on both branches,
                                                 nothing-capturable → nil, title carried
                                                 and title dropped
    .docs/092-ios-companion-plan.md              a dated note under S4b-ii
    .docs/093-ios-visual-design.md               a dated note under the failure card: the
                                                 fifth case, and the one sentence that
                                                 does not fit it

## Migration notes

None for users. Nothing ships on iOS yet, and no macOS behaviour changed.

**`SharedItem`'s shape changed.** `case image(bytes: Data, …)` is now
`case image(bytes: PayloadSource, …)`, and `ShareCaptureDraft.payload` is
`PayloadSource?` rather than `Data?`. Every construction site needs `.data(…)` around
bytes it used to pass bare; the label stayed `bytes:` deliberately, so the diff is one
wrapper and not a rename. This is source-breaking and loudly so — it will not compile
rather than misbehave.

**`InboxWriter` gained an entry point**, it did not lose one.
`write(_:payload: Data?, id:, capturedAt:)` is unchanged in signature and behaviour, so
every existing call site (the drain's tests, this package's own) still compiles. The new
`write(_:payload: PayloadSource?, …)` is the one to reach for when the bytes are a file,
and reaching for the old one instead means loading a file into memory to hand it to a
method that will write it straight back out. Note the new overload has **no default** for
`payload`: `write(request)` still resolves unambiguously to the `Data` version.

**`InboxWriteError` gained a case.** Any exhaustive `switch` over it outside this package
stops compiling — which is the intent, since `payloadTooLarge` is the one case that is
not an I/O failure and a `default:` would file it as one. It is also the one case that
carries no `underlying`; code reaching for that field generically should expect an empty
string rather than assume a sentence.

**The cap is enforced by the writer, not only by its caller.** A future producer that
writes to the inbox — a Mac-side importer, a second extension — inherits the refusal
without asking for it. That is deliberate: the limit protects the inbox contract, not
just the one process that happens to be small today. If it ever refuses something a user
legitimately wanted, `InboxWriter.maximumPayloadBytes` is one line and one number.
