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

## Files

    .docs/091-ios-companion-overview.md   new — the survey, six decisions, sizing,
                                          four open questions, follow-on index

## Migration notes

None — documentation only. Nothing is scheduled: 092 (design) and 093 (plan) are
named in the doc but unwritten, and the Safari-extension research doc is explicitly
gated on open question 1.
