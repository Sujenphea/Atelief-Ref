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

## The property that shapes the order

**S0–S3 are pure Swift that lands on the Mac app and needs no iOS target, no
device, and no provisioning.** They are testable with `swift test` under the
existing CI matrix, and each one improves the macOS build on its own terms. Only
S4 onward needs an Apple Developer provisioning change and a simulator.

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

## S4 — the iOS app target + share extension

The first slice that needs provisioning and a simulator.

- New `AtelierRefsMobile` app target + `AtelierRefsShare` share-extension target in
  the existing `AtelierRefs.xcodeproj`, both in the App Group.
- Extension links `AtelierCapture` + the S2 writer **only** — not `AtelierCore`,
  not `AtelierIngestion`, not GRDB. If the extension's link line ever grows GRDB,
  D2 has been violated; make that a review check, not a hope.
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

**~2 weeks.**

## S5 — read-only browse

Minimal SwiftUI: a `LazyVGrid` over the same `AppServices` reads the Mac grid
uses, plus item detail. **No `UICollectionView` bridge** — that is the iOS
re-run of the 037–039 bake-off, and it is not v1's problem. No Spaces, no canvas,
no reorder, no multiselect.

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

## Gates and risks

1. **App Group entitlement provisioning** blocks S4, not S0–S3. The Developer ID
   account already exists (052 · A3 / Sparkle), but the App ID needs the App Group
   capability added and profiles regenerated. Start this paperwork when S1 lands,
   not when S4 starts.
2. **Extension memory ceiling is not contractual.** ~120 MB is observed, not
   documented. S2's design (write bytes, decode nothing) is what makes the number
   irrelevant; do not let a "small optimization" pull decoding back into the
   extension.
3. **091 open question 1 — MAIN-world content scripts in iOS Safari — is not on
   this path.** It gates the tier-3 Safari Web Extension only. S0–S6 do not depend
   on the answer, which is why the plan does not wait for it.
4. **Deployment target.** The packages pin `.macOS("26.0")`; the iOS floor must be
   audited from the APIs actually used, not assumed. Do it during S4, when there
   is something to compile.

## Test strategy

`swift-testing` throughout (145 of 146 package test files use it; the lone XCTest
file is not a precedent). Per slice:

| Slice | Proof |
|---|---|
| S0 | the existing `AtelierServer` decode matrix, passing unmoved |
| S1 | override-branch parity on both platforms; a macOS root that is byte-identical to today's |
| S2 | writer matrix incl. partial write / missing payload / unreadable bytes |
| S3 | drain over a fixture inbox into a scratch library: dedup on retry, quarantine after 3, `.fileURL` not `.data` |
| S4 | first slice with XCUITest surface; keep it to a share-sheet smoke test |

CI: add `AtelierCapture` to the package matrix (`ci.yml:28`); add an iOS
simulator build job at S4.

## Sizing

| | |
|---|---:|
| S0–S3 (no iOS target, lands on the Mac) | **~2 weeks** |
| S4–S6 (needs provisioning + simulator) | **~5–6 weeks** |
| **Total to v1 companion** | **7–8 weeks** |

Slightly above 091's 5–7 week estimate: S0 was not costed there, and it is the
slice that keeps the two capture producers honest.

## Start here

S0. It is two days, it needs nothing new, it improves the desktop build on its
own merits, and it is the slice that decides whether the phone and the browser
extension are speaking the same contract or two that merely resemble each other.
