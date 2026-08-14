# 092 — iOS companion: implementation plan (S0–S6)

> The build order for the companion decided in
> [091](091-ios-companion-overview.md). Planned against the code as it actually
> stands on `feat/x-post-fidelity` (2026-08-14) — API-level specifics are cited
> inline so implementation doesn't re-derive them.
>
> 091 named a separate `092-design`; it is **folded into this doc** instead. The
> two contracts that needed designing (the shared capture DTO, the inbox record)
> are each half a page and belong beside the slice that builds them, the way
> [068](068-backup-portability-plan.md) carries F1–F3 inside the plan that
> consumes them. One doc, not two.
>
> **Amended 2026-08-14:** one design *did* earn its own doc —
> [093](093-ios-visual-design.md), the phone's visual surfaces. The contracts
> above are data shapes a slice either satisfies or doesn't; the share sheet,
> the navigation model and the grid rhythm are decisions with alternatives that
> have to be argued, and they span S4b and S5 rather than sitting inside either.
> Read 093 before writing any UI.

## The property that shapes the order

**S0–S3 are pure Swift that lands on the Mac app and needs no iOS target, no
device, and no provisioning.** They are testable with `swift test` under the
existing CI matrix, and each one improves the macOS build on its own terms. Only
S4b onward needs an Apple Developer provisioning change and a simulator — S4a,
split out of S4 once it was clear the package audit had none of those needs, is
pure Swift too.

So the plan front-loads everything that can be verified today, and reaches the
"needs an iOS target" cliff with the contract already proven. If the companion is
shelved after S3, nothing is wasted — S0 is a refactor the desktop wanted anyway.

## Naming decision (settled here, before any code)

The word **import** is taken three times already, all in the *user picks files* /
*replay a sweep* sense: `ImportFilesPanel`, `ImportPlan`, `ImportPasteboard`,
`ImportReplay`. **Archive** is taken by the portability round-trip
([068](068-backup-portability-plan.md)) and **backup** by the off-device copy. A
fourth overlapping term would make all four mean nothing.

The handoff directory is the **inbox**. Verbs: *drain the inbox*. Types:
`Inbox*` (`InboxRecord`, `InboxWriter`, `InboxDrain`). It is free in this
codebase — no symbol, doc, or changelog currently uses it.

---

## S0 — `AtelierCapture`: one capture contract, two producers

**Why first:** `CaptureRequest` / `ProvenanceDTO` / `decode(body:now:)`
(`CaptureDTO.swift:53`, `:284`, `:313`) already *are* the capture contract — a
validated funnel from untrusted JSON to `(Data, SourceDraft, UUID?)`, with a typed
`CaptureDecodeError` and a malformed-input test matrix behind it. The share
extension needs exactly that, and it must not fork a second copy: two decoders
over one wire shape is how provenance quietly diverges, and provenance is the
thing 18A dedup keys on (`LibraryArchive.swift:21`).

But it lives in `AtelierServer`, which depends on FlyingFox and is deleted on iOS
([091](091-ios-companion-overview.md) · the module table).

**Do:** extract `CaptureDTO.swift` into a new zero-dependency package
`AtelierCapture` (depends on `AtelierCore` only — it already imports nothing
else). `AtelierServer` gains a dependency on it; `CaptureRoutes`, `CaptureAuth`,
`JobDTO`, `JobRoutes` and the server tests stay where they are and re-import.

**Don't:** move `JobDTO`. Bulk sweeps are a desktop act driven by a browser
extension; nothing on the phone opens a job.

**Verify:** `swift test` in `AtelierServer` passes unchanged (the decode matrix is
the proof the extraction was behaviour-preserving); add `AtelierCapture` to the
CI matrix in `.github/workflows/ci.yml:28`.

**~2 days.** Pure refactor, no behaviour change.

> **As built** (2026-08-14, changelog
> [389](../.change-log/389-one-contract-two-producers.md)) — shipped, with three
> departures worth recording:
>
> 1. **The split line is finer than "move the file."** `CaptureResponse` stayed in
>    `AtelierServer` (new `CaptureResponse.swift`). The test is *does a producer of
>    captures need this?* — the request shape and its decode funnel have two
>    producers, but a reply is something only a server has, since a capture written
>    to the inbox has nobody to answer. Everything else moved, including
>    `VideoCaptureHeader` / `decodeVideoHeader` / `provenanceHeaderName`: they are
>    HTTP-shaped, but `CaptureDecodeError` carries their cases and an error enum
>    cannot be split across packages.
> 2. **An unplanned fourth target: `AtelierCaptureTestSupport`.** The decoder tests
>    moved with their code and immediately failed on `CaptureRequest.sample()` /
>    `jsonData()`, which lived in `AtelierServer`'s TestSupport — and SPM test
>    targets are not products, so the other package cannot reach them. Duplicating
>    the builder is precisely the drift S0 exists to prevent, so the image fixtures
>    and request builders became a shared test-only product both suites depend on.
>    The synthesized MP4 stayed behind: a video body is streamed over HTTP and has
>    no inbox counterpart.
> 3. **No `project.pbxproj` change was needed** — Xcode resolved `AtelierCapture`
>    transitively through `AtelierServer`'s path dependency, and the app target
>    built untouched. Good news for S4, which assumed package-graph surgery.
>
> Verification: 85 server tests before → 23 (`AtelierCapture`) + 62
> (`AtelierServer`) after, same total, all passing; app `xcodebuild build`
> succeeds; extension's 524 node tests + drift check unaffected (the
> cross-language `capture-contract.json` fixture is loaded by `#filePath` walk,
> and the moved suite sits at the same depth).

## S1 — `LibraryLocation`: the App Group seam

`defaultRoot()` (`LibraryLocation.swift:20`) resolves Application Support. On iOS
the app and its extension share nothing there; the root must come from
`containerURL(forSecurityApplicationGroupIdentifier:)`.

**Do:** platform-conditional base directory behind the same function —
`#if os(iOS)` returns the App Group container, macOS returns exactly what it
returns today. The `-library-root` / `ATELIER_LIBRARY_ROOT` override branch
(`LibraryLocation.swift:55`) is untouched: it is the throwaway-library escape
hatch the bake-offs and tests depend on, and it must keep resolving identically on
both platforms.

**Explicitly do NOT move the macOS library into a macOS App Group.** It would be
tidier-looking and it would cost a data migration of every existing user's
library for zero functional gain — macOS has no share extension to share with.
The container divergence is the point, not an inconsistency to iron out.

**Gate:** set the data-protection class on the library root explicitly to
`completeUntilFirstUserAuthentication` when creating it on iOS. Inheriting the
default risks a background drain on a locked device failing to open the database,
which is a bug that only reproduces on a real locked phone.

**~2 days**, plus the App Group entitlement provisioning (see Gates).

> **As built** (2026-08-14, changelog
> [394](../.change-log/394-only-the-base-differs.md)) — shipped as specified, with
> four decisions this section left open and one departure from the test row:
>
> 1. **The App Group is split by configuration**, matching the bundle IDs at
>    `project.pbxproj:377,413`: Debug `group.sujenphea.AtelierRefs.dev`, Release
>    `group.sujenphea.AtelierRefs`. One identifier would have put a dev build and a
>    release build into the same library.
> 2. **The identifier arrives via Info.plist**, key `AtelierAppGroupIdentifier`, whose
>    value is `$(ATELIER_APP_GROUP)` — a per-configuration build setting. Not a package
>    constant (it would have to be a pair, and know which build it is in) and not a
>    caller parameter (every call site would inherit the question). The plist sits next
>    to the entitlement that grants the container, and app and extension each read their
>    own. **The plist / build-setting / entitlement wiring is S4**; S1 built only the
>    read side.
> 3. **A nil container is a typed error, never a fallback.** `LibraryLocationError`
>    carries `appGroupIdentifierMissing(key:)` and
>    `appGroupContainerUnavailable(identifier:)`. `container ?? applicationSupport`
>    would let both processes open *different* libraries and succeed; what the user
>    sees then is shares that vanish, with nothing logged. A provisioning bug should
>    fail where it is fixable.
> 4. **The seam is a platform-free function, not a `#if` around the whole body.**
>    `defaultRoot()` is now *resolve a base, then `libraryRoot(under:)`*, and
>    `libraryRoot(under:)` — append `ref-atelier`, create, return — is shared by both
>    platforms so the naming and creation behaviour cannot drift. `#if os(iOS)` covers
>    the four-line container lookup and the `.protectionKey` call, nothing else. The
>    package stays `.macOS("26.0")`; the deployment-target audit is still S4's.
>
> **Departure:** the test row above asked for "override-branch parity on both
> platforms". That was met on macOS only — by construction rather than by an iOS build.
> Both platforms route through the same platform-free `libraryRoot(under:)`, and the
> Info.plist read takes its raw value as a parameter (defaulted to the `Bundle.main`
> lookup) so absent / blank both have tests. Building the iOS half would have meant
> adding `.iOS(...)` to a package that still contains
> `Input/DirectInputReader.swift`'s AppKit — i.e. doing S4's audit early to satisfy a
> test row. What remains unproven by `swift test` is the container lookup itself; it was
> type-checked against the iPhoneOS SDK directly (`swiftc -typecheck -target
> arm64-apple-ios18.0`) as a stopgap.
>
> Verification: 427 ingestion tests in 45 suites → 441 in 46 (14 new: macOS root
> identity, `libraryRoot(under:)` creation + idempotency, the three identifier failure
> paths, and the six override-branch cases); `AtelierServer` 62 and `AtelierCapture` 23
> unchanged; app `xcodebuild build` succeeds.

> **Amended** (2026-08-14, changelog
> [398](../.change-log/398-a-seam-ios-could-not-reach.md)) — S1 built the right seam
> in the wrong package, and S4a's cross-build audit is what exposed it. This section
> and the "As built" note above both describe `LibraryLocation` as living in
> `AtelierIngestion`; it now lives in `AtelierCapture`
> (`Sources/AtelierCapture/LibraryLocation.swift`), and its 14 tests moved with it.
>
> The defect was reachability, not behaviour. The `#if os(iOS)` branch decision 4
> describes exists so the **share extension** can find the library root — and
> `AtelierIngestion` imports AppKit in `Input/DirectInputReader.swift` and is
> deliberately not iOS-buildable, so the extension could never call `defaultRoot()`.
> A root-finder the extension cannot link is not a seam. `AtelierCapture` is
> transport-free, builds for iOS 26 since S4a, is already on the extension's link
> line, and is already where `InboxLayout` went in S2 for the identical reason: this
> is the second time the AppKit boundary has pulled a type out of `AtelierIngestion`.
>
> Nothing in decisions 1–4 changes, and the macOS root still resolves byte for byte —
> the moved suite's assertions were not touched, which is what makes that claim
> checkable. The macOS callers (`IngestionModel.swift`, `BakeoffSeedTests.swift`) each
> gained one `import AtelierCapture`; no re-export, since two imports is less churn
> and less indirection than an `@_exported` that would hide where the type lives from
> the extension that is about to link it directly. No `project.pbxproj` change was
> needed — `AtelierCapture` was already on the app's link line transitively through
> `AtelierIngestion`, so the streak below holds.

## S2 — `InboxRecord` + `InboxWriter`: what the extension writes

The share extension does the smallest durable thing and returns
([091](091-ios-companion-overview.md) · D2). It never opens SQLite, never decodes
an image, never links GRDB.

**Layout** — a sibling of `blobs/` / `thumbnails/` / `cache/` in `LibraryLayout`
(`LibraryLayout.swift:29`), added as a computed property so there is one authority
on where things live:

    <root>/inbox/<uuid>.json      the record
    <root>/inbox/<uuid>.bin       the payload bytes, when there are any

**Record** — `InboxRecord` is `Codable` and wraps the S0 contract rather than
restating it:

    struct InboxRecord: Codable, Sendable {
        var id: UUID
        var capturedAt: Date          // stamped in the extension, not at drain
        var request: CaptureRequest   // from AtelierCapture — provenance, kind, payload
        var payloadFile: String?      // "<uuid>.bin", when bytes were written
    }

`CaptureRequest.image` (the base64 field) is **left nil on this path** — bytes go
to the sidecar file so neither process holds a base64 string of an image in
memory. The field stays for the extension's HTTP producer, which is bounded by a
body cap and has no file to write to.

**Two-phase write, or the drain will race the writer.** Write `.bin` then
`.json`, each to `cache/` and moved into place — the drain treats a `.json` with
a `payloadFile` naming a file that is not there as *not yet complete*, and skips
it this pass rather than failing it. The record is the commit marker.

**Pure and testable with no iOS target:** writer and record are Foundation-only,
so the whole matrix (bytes present/absent, partial write, unreadable payload)
runs under `swift test` on macOS today.

**~3 days.**

> **As built** (2026-08-14, changelog
> [395](../.change-log/395-the-record-is-the-commit-marker.md)) — shipped, with four
> departures from the wording above:
>
> 1. **The code landed in `AtelierCapture`, not `AtelierIngestion`.** This section put
>    the layout in `LibraryLayout` and by implication the record and writer beside it,
>    but `AtelierIngestion` imports AppKit (`Input/DirectInputReader.swift`) and cannot
>    build for iOS at all — the share extension could never link it. `InboxRecord`,
>    `InboxWriter` and a new `InboxLayout` live in `AtelierCapture`, which is
>    transport-free and which the extension already links. `InboxLayout` owns
>    `directoryName`, `AtelierIngestion` gained a dependency on `AtelierCapture`, and
>    `LibraryLayout.inbox` delegates — so there is still exactly one authority on where
>    the handoff lives; the arrow just points the other way. No cycle: AtelierCapture →
>    AtelierCore, AtelierIngestion → AtelierCore + AtelierCapture.
> 2. **Staging is `inbox/.staging/`, not `cache/`.** `cache` is a name `LibraryLayout`
>    owns, and a package that must not learn the library's directory structure should
>    not learn a second directory name in order to write one file. Same volume, so the
>    move is still a rename; and the drain's top-level `*.json` enumeration cannot see
>    a dot-directory, which is the property that makes staged files invisible.
> 3. **`InboxRecord` carries `attempts` from the start**, defaulted to 0 and written by
>    S3's drain, rather than being added when quarantine lands. This is an on-disk
>    format written by a possibly-older shipped extension and read by a newer host;
>    adding the field in S3 would mean tolerating records that predate it forever. The
>    decode tolerates a missing `attempts` anyway — one line, and the format is on disk.
> 4. **The GRDB claim in S4 was wrong and is corrected.** `AtelierCapture` depends on
>    `AtelierCore`, which depends on GRDB, so GRDB is on the extension's link line
>    today. Accepted: linked is not opened, and the ceiling is about dirty memory. The
>    S4 bullet now asks for a measurement rather than an assertion, and
>    [389](../.change-log/389-one-contract-two-producers.md) carries a dated correction
>    note.
>
> Also settled here: `InboxLayout.payloadURL(named:)` refuses any `payloadFile` that is
> not a single plain path component, because that string arrives from a file written by
> another process; and the writer drops `CaptureRequest.image` when it has just written
> the same bytes to a sidecar, but leaves it alone when there is no sidecar, so a
> base64-only capture is shrunk rather than lost.
>
> Verification: `AtelierCapture` 23 tests in 1 suite → 38 in 2; `AtelierIngestion` 441
> in 46 → 445 in 47; `AtelierServer` 62 in 6 unchanged; app `xcodebuild build`
> succeeds. The new sources were type-checked against the iPhoneOS SDK
> (`swiftc -typecheck -target arm64-apple-ios26.0 -swift-version 6`) with the capture
> contract stubbed — a full `swift build --triple arm64-apple-ios26.0` cannot run until
> S4 adds the `.iOS(...)` platform lines (see the note in S4).

## S3 — `InboxDrain`: the host side

Modelled on `startCaptureEndpoint` (`IngestionModel.swift:885`), which is the
existing precedent for "an outside producer feeds the same bounded coordinator":
same `IngestCoordinator`, no second queue, main-actor hop to refresh the UI.

**Do:** `InboxDrain` reads each record, maps it through the S0 decode seam, and
builds `IngestInput` with **`ByteSource.fileURL`** (`IngestInput.swift:19`) —
never `.data`. The bytes are already on disk; reading them into memory to hand
them to a pipeline that will write them back out is the one mistake this whole
design exists to avoid. Media-less records (`kind` = `tweet`/`link`/`color`) take
the `AssetContentDraft` initializer (`IngestInput.swift:86`) and carry no file.

Target collection: `decoded.collectionID ?? Collection.unsortedID`
(`Collection.swift:18`) — **the same default the capture endpoint already uses**
(`IngestionModel.swift:893`). This settles 091's open question 2: a share with no
context lands in Unsorted, exactly where a browser capture with no target lands.
No new "Inbox collection" concept, no picker in the extension, no read-only
collection tree crossing the process boundary.

Delete the record and its payload **only after** the outcome is `.ingested` or a
terminal failure; a crash mid-drain re-runs the item, and 18A blob-hash dedup
makes the retry a no-op rather than a duplicate. Retry-forever is the failure mode
to avoid: stamp an attempt count into the record and quarantine to
`inbox/failed/` after 3.

**Run it on macOS first.** The drain is platform-free, so it can be wired into the
Mac app behind the `-library-root` override and exercised by dropping records into
a scratch library — the whole path is provable before an iOS target exists.

**~4 days.**

> **As built** (2026-08-14, changelog
> [396](../.change-log/396-the-drain-owns-nothing.md)) — shipped, with three
> departures from the wording above and one shape this section did not specify:
>
> 1. **`InboxDrain` exposes a single pass, not a running thing.**
>    `drainOnce() async -> DrainSummary` — no timer, no `DispatchSource`, no
>    `start()`/`stop()`, no state between calls. The caller owns cadence, so S4 can
>    drive it at launch, on foreground, or from a watcher without this package having
>    an opinion; and every test is deterministic with nothing to wait on. The summary
>    is `Equatable` and counts the four terminal fates of a record (ingested /
>    skipped-incomplete / quarantined / retrying), so a pass is asserted as a value
>    rather than reconstructed from side effects.
> 2. **"Run it on macOS first" happened in tests, not in the app. No app-target
>    changes at all.** This section said to wire the drain into the Mac app behind the
>    `-library-root` override; that moves to **S4**. There is no producer until the
>    share extension exists, so the call site's only possible input would be a
>    directory nothing writes to — dead code, plus a UI-refresh hook with nothing to
>    refresh from. The path is proven instead by a fixture inbox written with the real
>    `InboxWriter` draining into a real migrated library through the real coordinator,
>    under `swift test`. `IngestionModel.swift` was read as the model for the
>    coordinator seam and left untouched; `project.pbxproj` again needed no change.
> 3. **A malformed `payloadFile` quarantines on the first pass, `attempts`
>    untouched.** The three-attempt budget is for transient failures — disk, decode,
>    coordinator pressure. A name `InboxLayout.payloadURL(named:)` refuses is
>    malformed and will never become valid, so retrying it is waste. The same applies,
>    forced rather than chosen, to a `.json` that will not decode: there is nowhere to
>    stamp an attempt on a record that will not parse, and an atomically-moved record
>    is whole or absent, so undecodable means malformed rather than early.
>
> Also settled here: the target collection is `collectionId ?? Collection.unsortedID`
> as specified, closing 091's open question 2; deletion after a successful ingest
> removes the **record first** (a payload with no record is a leak nothing enumerates,
> while a record whose payload is gone is permanently incomplete and would be skipped
> forever); and the attempt stamp re-commits through a new `InboxWriter.rewrite(_:)`
> sharing the writer's phase 2, rather than a second commit path in `AtelierIngestion`.
> `inbox/failed/` is a plain subdirectory, not a dot-directory — a quarantined capture
> is meant to be found — and both it and `.staging/` are now *tested* as invisible to
> `pendingRecordURLs()` rather than assumed to be.
>
> Two seams were added to `CaptureDecoder` so the second producer reuses the funnel
> instead of re-deriving it: `decodeInput(_ request:now:)` (the body-taking entry point
> is now *decode, then this*; a funnel reachable only through a deserializer would grow
> a second copy) and `decodeFileInput(_:now:)` → `DecodedFileInput`, the same routing
> for a capture whose bytes are a file, reusing `DecodedVideoCapture` /
> `DecodedContentCapture` rather than declaring a fourth near-identical struct.
> `DirectInputReader` gained `remoteFile` and `remoteContentWithFile`.
>
> Verification: `AtelierIngestion` 445 tests in 47 suites → 461 in 48; `AtelierCapture`
> 38 in 2 → 43 in 2; `AtelierServer` 62 in 6 unchanged; app `xcodebuild build`
> succeeds. The changed `AtelierCapture` sources were type-checked against the iPhoneOS
> SDK again (`swiftc -typecheck -target arm64-apple-ios26.0 -swift-version 6`, contract
> stubbed), including `replaceItemAt`.

## S4 — split into S4a and S4b

S4 as written above bundled two jobs with nothing in common: making the *packages*
compile for iOS, and creating the *Xcode targets* that link them. The first is pure
Swift, needs no provisioning, no simulator and no project-file change, and gates the
second completely — nothing can link `AtelierCapture` on iOS until `AtelierCapture`
builds on iOS. The second is where the entitlements, the plists and two hand-made
targets live.

They are split so the package audit could land on its own terms, the way S0–S3 did,
and so the provisioning work is not blocked on an unknown-size port.

### S4a — the package-level iOS audit

Discharge risk 4: declare the iOS floor on the two packages the share extension
links, cross-build them, and guard or port whatever the compiler rejects. Scope is
`AtelierCore` + `AtelierCapture` **only** — `AtelierIngestion` imports AppKit
(`NSPasteboard` in `Input/DirectInputReader.swift`) and is host-side by design;
`AtelierServer`, `CanvasRenderer` and `AtelierExport` are things the phone never
does. Porting any of them is a later, separately-costed decision, not a side effect
of this slice.

**~1 day.**

> **As built** (2026-08-14, changelog
> [397](../.change-log/397-nothing-to-guard.md)) — shipped, and it was two lines.
>
> 1. **The blocker was purely declarative.** With `.iOS("26.0")` added beside the
>    existing `.macOS("26.0")` in both manifests, `AtelierCore` (218 compile tasks,
>    GRDB included) and `AtelierCapture` both build clean for
>    `arm64-apple-ios26.0` with **zero source changes, zero `#if os(macOS)` guards
>    and zero `@available` annotations**. The public surface is byte-identical on
>    both platforms, so S5 inherits no divergence.
> 2. **The floor is 26.0, mirroring macOS**, not derived downward from the APIs
>    used. Both packages ship inside the companion app and its extension, built
>    from the same sources by the same toolchain; a lower floor would only buy
>    `@available` guards for versions nothing installs.
> 3. **`--triple` alone is not enough.** The command this doc recorded,
>    `swift build --triple arm64-apple-ios26.0`, gets past dependency resolution
>    and then fails every target with *"unable to load standard library for target
>    arm64-apple-ios13.0"* — SwiftPM stays on the host's macOS SDK. The working
>    invocation adds `--sdk "$(xcrun --sdk iphoneos --show-sdk-path)"`, and that
>    is what CI runs. (The `ios13.0` in the message is GRDB compiling at its own
>    declared minimum; it is not a constraint on us.)
> 4. **One thing S4b would have hit immediately, discovered here:** `LibraryLocation`
>    — the App Group seam S1 built *for iOS* — lived in `AtelierIngestion`, which
>    does not build for iOS. The extension therefore could not call `defaultRoot()`
>    to find the library root it is supposed to write into. **Fixed the same day**
>    by moving the seam into `AtelierCapture` — see the amendment under S1
>    (changelog [398](../.change-log/398-a-seam-ios-could-not-reach.md)). S4b starts
>    with a reachable root-finder.
>
> Verification: both iOS builds succeed and emit genuine iOS objects
> (`LC_BUILD_VERSION` platform 2, minos 26.0, sdk 26.5); the entire macOS matrix
> is unchanged at AtelierCore 760/105 · CanvasRenderer 437/52 · AtelierExport 84/7
> · AtelierIngestion 461/48 · AtelierCapture 43/2 · AtelierServer 62/6 · 524 node
> tests + drift check; app `xcodebuild build` succeeds. No `project.pbxproj`
> change, for the fifth slice running.

### S4b — the iOS app target + share extension

The first slice that needs provisioning and a simulator.

**Division of labour, decided by the user:** the two Xcode targets are created **by
hand, by the user, in Xcode** — a new `AtelierRefsMobile` app target and an
`AtelierRefsShare` share-extension target in the existing `AtelierRefs.xcodeproj`,
both in the App Group. Everything else is written by the agent: all sources, the
Info.plist keys (including S1's `AtelierAppGroupIdentifier` = `$(ATELIER_APP_GROUP)`
on both targets), the entitlements files, and the `ATELIER_APP_GROUP`
per-configuration build setting (Debug `group.sujenphea.AtelierRefs.dev`, Release
`group.sujenphea.AtelierRefs`, per S1 · decision 1). A hand-made target avoids the
one thing five slices have so far avoided: a generated `project.pbxproj` diff nobody
can review.

> **Amended 2026-08-14 — the targets exist, and the division of labour above did not
> survive contact** (changelog [400](../.change-log/400-the-pen-changed-hands.md)).
> Xcode's target sheet was driven three times and produced a **separate**
> `AtelierRefsMobile.xcodeproj` each time, alongside a correctly-placed
> `AtelierRefsShare` in the main project. The pbxproj was therefore reconciled by
> hand, by the agent — the diff nobody wanted to review is the diff that exists, and
> the compensation is that it is small, hand-written rather than generated, and
> gated (see the changelog's verification table). The `AtelierRefs` and
> `AtelierRefsTests` targets, their build settings, and `Config/Release.xcconfig`
> were not touched.
>
> **As built** — one project, `AtelierRefs/AtelierRefs.xcodeproj`, four targets:
> `AtelierRefs` (macOS), `AtelierRefsTests`, `AtelierRefsMobile` (iOS app),
> `AtelierRefsShare` (iOS share extension, embedded in `AtelierRefsMobile` through a
> `PBXCopyFilesBuildPhase` with `dstSubfolderSpec = 13` and a target dependency —
> that phase is what makes the share sheet appear on device). Sources sit beside the
> macOS ones, `AtelierRefsMobile/` and `AtelierRefsShare/`, both as
> `PBXFileSystemSynchronizedRootGroup`s like the two targets that were already there.
>
> Both iOS targets carry `SDKROOT = iphoneos`, `IPHONEOS_DEPLOYMENT_TARGET = 26.0`
> (matching the packages' `.iOS("26.0")` floor from S4a), `SWIFT_VERSION = 6.0`,
> `TARGETED_DEVICE_FAMILY = 1`, `DEVELOPMENT_TEAM = L25247V6JG`,
> `GENERATE_INFOPLIST_FILE = YES`, `PRODUCT_NAME = $(TARGET_NAME)` and
> `CODE_SIGN_STYLE = Automatic` on **both** configurations — the macOS app's Release
> `Manual` is for Developer ID and there is no iOS distribution profile to be manual
> about yet. Bundle identifiers are `sujenphea.AtelierRefsMobile` and
> `sujenphea.AtelierRefsMobile.Share`; the sheet had produced the non-nesting
> `sujenphea.AtelierRefsShare`, which an App Group grant would have had to work
> around. The extension keeps `INFOPLIST_FILE = AtelierRefsShare/Info.plist`.
>
> **App Groups is still the user's step, on purpose.** No `CODE_SIGN_ENTITLEMENTS` is
> set on either new target and no `.entitlements` file was written: Signing &
> Capabilities generates the correctly-shaped file *and* registers the group with the
> App ID, which no pbxproj edit can do. Gate 1's paperwork is the blocker it always
> was. Nothing links a Swift package into either target yet either — that is the next
> slice, and it is the seam the bullets below describe.

> **As built — S4b-i, the App Group wiring** (2026-08-14, changelog
> [401](../.change-log/401-one-variable-eight-places.md)). S4b is split in two, and
> this is the first half: the seam resolves on iOS, and the extension's behaviour is
> S4b-ii. The user added App Groups through Signing & Capabilities — the half that
> registers the group against the App ID — and everything from the literal identifier
> onward is this slice.
>
> 1. **One variable, eight places.** `ATELIER_APP_GROUP` is a user-defined build
>    setting defined four times (two targets × two configurations) per decision 1's
>    values, and read by four consumers per configuration: both `.entitlements` files
>    and both Info.plists, none of which contains a literal identifier. The entitlement
>    is what the system *grants*; the plist key is what the process *asks for*. A build
>    where they disagree compiles, signs and launches, and then hands the app and its
>    extension different containers — feeding both from one variable is the only
>    arrangement in which that cannot happen.
> 2. **`INFOPLIST_KEY_<arbitrary>` does not reach a generated plist.**
>    `INFOPLIST_KEY_AtelierAppGroupIdentifier` on `AtelierRefsMobile` was accepted with
>    no warning and dropped from the built Info.plist. The setting covers only keys
>    Xcode knows. The target now has a real `AtelierRefsMobile/Info.plist` carrying that
>    one key, with `GENERATE_INFOPLIST_FILE` still `YES` so the generated keys merge
>    over it — the arrangement the macOS app and `AtelierRefsShare` were already using —
>    plus a `PBXFileSystemSynchronizedBuildFileExceptionSet` so the file is not also
>    copied in as a resource. Verified by reading the key back out of the built product,
>    which is the only check that distinguishes this from a green build.
> 3. **`AtelierCapture` is on both iOS link lines**, the first package linked into
>    either target: a sixth `XCLocalSwiftPackageReference`, a product dependency and a
>    frameworks build file per target. `AtelierCore` and GRDB come transitively.
>    `AtelierIngestion`, `AtelierServer`, `AtelierExport` and `CanvasRenderer` are not
>    linked and do not build for iOS.
> 4. **`ContentView.swift` is a temporary diagnostic**, not UI — it resolves
>    `defaultRoot()` and shows the path or the typed error, marked as such in its first
>    line. [093](093-ios-visual-design.md) replaces the file in S5.
>
> Verification: macOS `build` and `build-for-testing` both succeed; iOS builds succeed
> on Debug *and* Release, which is the point of the split; the whole package matrix is
> unchanged at AtelierCore 760/105 · CanvasRenderer 437/52 · AtelierExport 84/7 ·
> AtelierIngestion 447/47 · AtelierCapture 57/3 · AtelierServer 62/6. All eight
> extracted identifiers agree — `group.sujenphea.AtelierRefs.dev` in the app plist, the
> appex plist and both entitlements on Debug, `group.sujenphea.AtelierRefs` in all four
> on Release. Launched on a simulator the app prints a real shared-container path and
> `ref-atelier/` exists under it afterwards, so S1's `#if os(iOS)` branch has now
> executed rather than merely compiled.
>
> **What S4b-ii still owns:** everything below this note except the first bullet — the
> extension's actual capture behaviour (tiers 1 and 2, the platform mapping,
> `InboxWriter` on the extension's side), the footprint measurement against the ~120 MB
> ceiling, the share-sheet UI per [093](093-ios-visual-design.md), and the two app-side
> seams S3 deferred (`InboxDrain.drainOnce()` behind the `-library-root` override and
> its `onCapture` equivalent).

- **`LibraryLocation` is reachable from iOS — done, not pending.** The seam moved to
  `AtelierCapture/Sources/AtelierCapture/LibraryLocation.swift` on 2026-08-14
  (changelog [398](../.change-log/398-a-seam-ios-could-not-reach.md), amendment under
  S1), so the extension can call `defaultRoot()` on its own link line. What is left
  for this slice is the wiring the seam *reads*: `Bundle.main` in an app extension is
  the **extension's** bundle, not the host app's, so the share extension needs its own
  `AtelierAppGroupIdentifier` key fed by the same `$(ATELIER_APP_GROUP)` build
  setting. Two plists, one setting, one identifier.
- Extension links `AtelierCapture` + the S2 writer **only** — not `AtelierIngestion`,
  and nothing that opens a database. It does link `AtelierCore`, and therefore GRDB:
  `AtelierCapture` needs `SourceDraft` / `Platform` / `AssetContentDraft`, and
  `AtelierCore` depends on GRDB (`AtelierCore/Package.swift:31`). That was mis-stated
  in [389](../.change-log/389-one-contract-two-producers.md) and corrected there.
  Linked is not opened: D2's invariant is that the extension never *instantiates* a
  `DatabasePool` and never decodes an image, both of which are behaviours. **The gate
  is a measurement, not an assertion about the link line** — profile the extension's
  actual footprint against the ~120 MB ceiling with a large share, since that ceiling
  is about dirty memory and linked code pages are not dirty. Removing GRDB from the
  link line would mean splitting the domain types out of `AtelierCore`, which is a
  much larger refactor than the number justifies.
- Tier 1 (share from a native app): `NSExtensionItem` yields a URL →
  `CaptureRequest(kind: "link", …)`, and the host resolves og-tags at drain time
  via the existing `PageResolver` (cookie-less by design,
  `PageResolver.swift:10`).
- Tier 2 (share from Safari): `NSExtensionJavaScriptPreprocessingFile` returns a
  DOM-scraped dictionary → richer `ProvenanceDTO` + a direct media URL. The
  extractors in `extension/src/extractors/` are the reference; port the smallest
  useful subset (twitter, instagram, pinterest) rather than all five.
- **Platform mapping:** map the URL host to `Platform` (`Enums.swift:43`), falling
  back to `.web`. Record the *act* as `rawMetadata.capturedVia = "ios_share"`.
  Do **not** add a `Platform` case for sharing — `platform` records which site the
  content is from, the value is persisted as a string in SQLite, and a new case
  touches the migrator, every filter, and the archive contract. `clipboard` /
  `localPaste` / `localDrag` are the existing exceptions and they are not a
  precedent worth extending for this.
- Plus the two app-side seams S3 deferred: wiring `InboxDrain.drainOnce()` into the
  Mac app behind the `-library-root` override, and giving it the equivalent of
  `CaptureRoutes`' `onCapture` hook so a drained share refreshes the live UI.

**~2 weeks.**

## S5 — read-only browse

Minimal SwiftUI over the same `AppServices` reads the Mac grid uses, plus item
detail. **No `UICollectionView` bridge** — that is the iOS re-run of the 037–039
bake-off, and it is not v1's problem. No Spaces, no canvas, no reorder, no
multiselect.

> **Superseded 2026-08-14** — this section said "a `LazyVGrid`", which quietly
> decided the library's *rhythm*: the Mac grid is masonry, and `LazyVGrid` is
> uniform. [093](093-ios-visual-design.md) makes that a decision instead of an
> accident, and lands on masonry via `C` lazy column stacks — `MasonryLayout` is
> round-robin fixed-column (`MasonryLayout.swift:96`), so column membership is a
> function of the index and the layout decomposes per column with no solver
> ported and laziness intact. Uniform `LazyVGrid` remains the stated fallback.
> The exclusions above are unchanged, and 093 does not reopen the bake-off.

**~2–3 weeks.**

## S6 — one-way sync over the archive manifest

The phone writes a `LibraryArchive`-shaped archive
([068](068-backup-portability-plan.md) · H6) of what it captured; the Mac imports
it (H7). Idempotent by construction — provenance is copied verbatim so re-import
collapses on blob hash rather than forking a second asset
(`LibraryArchive.swift:21`).

Transport in v1 is whatever moves a folder: AirDrop, iCloud Drive, a cable.
Deliberately not a sync service — 091 · D4.

**~1–1.5 weeks.**

---

## Where this stands (2026-08-14)

**S0–S3 and S4a are done** — [389](../.change-log/389-one-contract-two-producers.md),
[394](../.change-log/394-only-the-base-differs.md),
[395](../.change-log/395-the-record-is-the-commit-marker.md),
[396](../.change-log/396-the-drain-owns-nothing.md),
[397](../.change-log/397-nothing-to-guard.md). That is the whole no-provisioning
run: the capture contract has one funnel and two producers, the library root has an
App Group seam, the extension's write and the host's drain both exist, the
capture-to-library path is provable end to end under `swift test` on macOS with no
iOS target and no device — and the two packages the extension links now compile for
iOS 26 and are held there by CI.

**S4b-i is done too** ([401](../.change-log/401-one-variable-eight-places.md)) — the
targets exist, both are in the App Group, both link `AtelierCapture`, and
`LibraryLocation.defaultRoot()` resolves a real shared container on a simulator. The
seam S1 built for iOS has now run on iOS. **S4b-ii is the open slice**: the extension's
capture behaviour, the footprint measurement, the share-sheet UI from
[093](093-ios-visual-design.md), and the two app-side seams S3 deferred.

What S4b inherits, all of it recorded rather than discovered later:

- **The platform-pin blocker is gone, and it was only a declaration.** `.iOS("26.0")`
  on `AtelierCore` and `AtelierCapture` was the entire fix: no guards, no ports, no
  `@available`, no public-surface divergence between platforms. The real invocation
  is `swift build --triple arm64-apple-ios26.0 --sdk "$(xcrun --sdk iphoneos
  --show-sdk-path)"` — `--triple` alone leaves SwiftPM on the host macOS SDK — and it
  runs in CI as the `ios-packages` job so the cleanliness cannot silently regress.
- **S1's App Group seam is now reachable from iOS.** `LibraryLocation` moved out of
  `AtelierIngestion` — which imports AppKit and does not build for iOS — into
  `AtelierCapture`, tests and all, on 2026-08-14
  ([398](../.change-log/398-a-seam-ios-could-not-reach.md)). It was S4b's first task
  and it is off the critical path. The second time the AppKit boundary has relocated
  a type; if a third one appears, the boundary is the finding, not the type.
- **A measurement, not an assertion, for the extension's footprint.** 395 corrected
  389: GRDB is on the extension's link line transitively through `AtelierCore` and no
  reachable change removes it. The gate is profiling actual dirty memory against the
  ~120 MB ceiling with a large share; the invariant that still holds is behavioural —
  the extension opens no database and decodes no image.
- **The App Group entitlement paperwork is closed** ([401](../.change-log/401-one-variable-eight-places.md)).
  Gate 1 is discharged: the capability is registered against the App ID, both targets
  carry an entitlements file, and the write side S1 deferred — the
  `$(ATELIER_APP_GROUP)` per-configuration build setting and the
  `AtelierAppGroupIdentifier` key in *both* plists — is wired and read back out of the
  built products on both configurations. The trap it cost: `INFOPLIST_KEY_<arbitrary>`
  is silently dropped from a generated Info.plist, so a green build proves nothing here
  and `AtelierRefsMobile` needed a real plist file.
- **The `project.pbxproj` streak is over, and it ended badly** — five slices plus the
  S4a correction went by with no diff at all, because path dependencies resolved
  transitively every time and the link line never moved. S4b stopped it, as predicted.
  What was not predicted is who held the pen: Xcode's target sheet produced a separate
  `AtelierRefsMobile.xcodeproj` on three attempts, so the reconciliation into one
  four-target project was written by hand by the agent
  ([400](../.change-log/400-the-pen-changed-hands.md), amendment under S4b). The
  package graph moved next: S4b-i put `AtelierCapture` on both iOS link lines as the
  project's sixth local package reference, so the pbxproj is now a file this work
  touches routinely rather than one it has never opened.
- **Two app-side seams were deliberately deferred into S4b** rather than shipped
  without callers: wiring `InboxDrain.drainOnce()` into the app behind the
  `-library-root` override, and giving it the equivalent of `CaptureRoutes`'
  `onCapture` hook so a drained share refreshes the live UI.

## Gates and risks

1. ~~**App Group entitlement provisioning**~~ **Discharged in S4b-i**
   ([401](../.change-log/401-one-variable-eight-places.md)). The capability is
   registered against the App ID, both iOS targets carry an entitlements file fed by
   `$(ATELIER_APP_GROUP)`, and the container resolves on a simulator on both
   configurations. It blocked S4b, not S0–S4a, and it no longer blocks anything.
2. **Extension memory ceiling is not contractual.** ~120 MB is observed, not
   documented. S2's design (write bytes, decode nothing) is what makes the number
   irrelevant; do not let a "small optimization" pull decoding back into the
   extension.
3. **091 open question 1 — MAIN-world content scripts in iOS Safari — is not on
   this path.** It gates the tier-3 Safari Web Extension only. S0–S6 do not depend
   on the answer, which is why the plan does not wait for it.
4. ~~**Deployment target.**~~ **Discharged in S4a**
   ([397](../.change-log/397-nothing-to-guard.md)). `AtelierCore` and
   `AtelierCapture` pin `.iOS("26.0")` beside `.macOS("26.0")` and cross-build
   clean with no guards and no API divergence; the `ios-packages` CI job holds it.
   The floor was set to match macOS rather than derived from the APIs used — both
   packages only ever ship inside a macOS 26 / iOS 26 app, so a lower floor buys
   `@available` guards for versions nothing installs. The other four packages
   still declare macOS only, on purpose.

## Test strategy

`swift-testing` throughout (145 of 146 package test files use it; the lone XCTest
file is not a precedent). Per slice:

| Slice | Proof |
|---|---|
| S0 | the existing `AtelierServer` decode matrix, passing unmoved |
| S1 | override-branch parity on both platforms; a macOS root that is byte-identical to today's |
| S2 | writer matrix incl. partial write / missing payload / unreadable bytes |
| S3 | drain over a fixture inbox into a scratch library: dedup on retry, quarantine after 3, `.fileURL` not `.data` |
| S4a | `swift build --triple arm64-apple-ios26.0 --sdk …` on both packages, in CI |
| S4b | first slice with XCUITest surface; keep it to a share-sheet smoke test |

CI: `AtelierCapture` is in the package matrix (`ci.yml`), and the `ios-packages`
job cross-builds `AtelierCore` + `AtelierCapture` for `arm64-apple-ios26.0`. It is
build-only — a test bundle needs a simulator host, so the compile is the gate. An
iOS simulator *test* job arrives with S4b's XCUITest.

## Sizing

| | |
|---|---:|
| S0–S4a (no iOS target, lands on the Mac) | **~2 weeks** |
| S4b–S6 (needs provisioning + simulator) | **~5–6 weeks** |
| **Total to v1 companion** | **7–8 weeks** |

Slightly above 091's 5–7 week estimate: S0 was not costed there, and it is the
slice that keeps the two capture producers honest.

## Start here

S0. It is two days, it needs nothing new, it improves the desktop build on its
own merits, and it is the slice that decides whether the phone and the browser
extension are speaking the same contract or two that merely resemble each other.
