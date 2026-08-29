# 388 — the part a phone is good at

A reconnaissance pass over the whole tree, answering "what would it take to have this
on iOS, where I share into it from the share sheet?" No code changed;
[091](../.docs/091-ios-companion-overview.md) is the output.

The measurement is the finding. Of ~72k lines of source, **~18k move for the cost of a
`platforms:` line** — `AtelierCore` (0 AppKit files), `AtelierExport` (0), the whole of
`AtelierIngestion` bar `DirectInputReader.swift`, and the pure ~2.1k of
`CanvasRenderer`. That is the package-boundary discipline from 001/003 paying out
years later against a question nobody was asking when the boundaries were drawn.

The 46k-line app target is the port, and not because of API mismatches.
`MasonryGridHost` (2,113 lines, 147 NS-symbols) is an NSCollectionView bridge that
*won a measured bake-off* (037–039); on iOS that decision re-opens rather than
translates. Marquee-select, hover, right-click and drag-with-modifiers are four
interaction primitives touch does not have, and Spaces is built on all four.

So the recommendation is a **companion, not a port**: share sheet → App Group inbox →
one-way sync to the Mac, plus read-only browse. Scope chosen so that the reused
surface is exactly the part that ports free.

Four decisions worth naming outside the doc:

- **The share extension writes an inbox record; it does not ingest.** Extensions run
  on a much tighter memory budget than the host, and `IngestPipeline` decodes
  originals — a large share would jetsam into a share sheet that silently does
  nothing. The extension appends files; the host drains them through the *existing*
  `IngestCoordinator`. One process opens the `DatabasePool`, and that stays true by
  construction rather than by care.
- **Sync rides the archive manifest.** `LibraryArchive`'s import idempotency exists
  because provenance is copied verbatim so 18A blob-hash dedup collapses re-imports
  (rule 1 of its header). An iOS capture set is expressible as a small archive, so
  one-way merge is a solved path — and one-way has no conflicts to resolve, which
  CloudKit would.
- **iOS fidelity is a different capture, in three tiers.** Share from a native app
  gives a URL and nothing more, so `PageResolver`'s cookie-less og-tag path is the
  ceiling. Share from Safari gives a URL *plus DOM*, via
  `NSExtensionJavaScriptPreprocessingFile` — the extractors in `src/extractors/` are
  largely reusable there. Neither reaches what `twitter-hook.js` does, because
  interception needs a `document_start` that a share sheet does not have. Only a
  Safari Web Extension port would, and that is gated on whether iOS Safari supports
  MAIN-world content scripts at all — the doc's first open question, and the one that
  decides whether tier 3 exists.
- **No in-app logged-in WKWebView.** It would restore parity. It is also a new
  product surface with review and ToS exposure, and it is not being decided in
  passing.

v1 sizes at 5–7 weeks; a feature-comparable iOS app at 3–5 months. The gap between
those two numbers is the argument.

## The build order, and the slice nobody costed

[092](../.docs/092-ios-companion-plan.md) turns that into S0–S6. The ordering
property worth stating outside the doc: **S0–S3 are pure Swift that land on the Mac
app and need no iOS target, no device and no provisioning.** They run under the
existing `swift test` matrix, and each improves the desktop build on its own terms.
The plan reaches the "needs an iOS target" cliff with the contract already proven,
and if the companion is shelved at S3 nothing is wasted.

S0 is the slice 091 missed. `CaptureRequest` / `decode(body:now:)` already *are* the
capture contract — a validated funnel from untrusted JSON to
`(Data, SourceDraft, UUID?)` with a malformed-input matrix behind it — but they live
inside `AtelierServer`, which links FlyingFox and does not exist on iOS. Extracting
them to a zero-dependency `AtelierCapture` package is two days, changes no behaviour,
and is what keeps the phone and the browser extension speaking one contract rather
than two that resemble each other. It pushes the total from 5–7 weeks to 7–8.

Three decisions the plan settles that the overview had left open or unasked:

- **A share lands in Unsorted** — `decoded.collectionID ?? Collection.unsortedID`,
  the exact default `startCaptureEndpoint` already uses. 091's open question 2 is
  closed with no new concept: no Inbox collection, no picker in the extension, and
  nothing about the collection tree crossing the process boundary.
- **The macOS library does not move into an App Group.** The container base is
  iOS-only, behind a platform conditional in `LibraryLocation`. Unifying the two
  would look tidier and would cost a data migration of every existing library for
  zero functional gain — macOS has no share extension to share with.
- **No new `Platform` case for sharing.** `platform` records which *site* the
  content came from and is persisted as a string; a new case touches the migrator,
  every filter and the archive contract. The host is mapped to the existing cases
  with a `.web` fallback, and the act is recorded as
  `rawMetadata.capturedVia = "ios_share"`.

The drain ingests through `ByteSource.fileURL`, never `.data` — the bytes are
already on disk, and reading them into memory to hand them to a pipeline that writes
them back out is the mistake the whole design exists to avoid. Records are two-phase
(payload, then record-as-commit-marker) so a drain running against a mid-write
extension skips rather than fails, and deletion happens only after a terminal
outcome, with 18A dedup making the crash-retry a no-op.

## Files

    .docs/091-ios-companion-overview.md   new — the survey, six decisions, sizing,
                                          four open questions, follow-on index
    .docs/092-ios-companion-plan.md       new — S0–S6, the inbox + capture-DTO
                                          contracts, gates, per-slice test strategy

## Migration notes

None — documentation only. Nothing is built. 091 planned a separate `092-design`;
it was folded into the plan, so 093 is unallocated and the Safari-extension research
doc remains gated on open question 1 (whether iOS Safari supports MAIN-world content
scripts at `document_start`) — which S0–S6 deliberately do not depend on.
