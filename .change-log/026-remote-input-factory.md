# 026 — Remote-input provenance factory (build-order #6, checkpoint 1)

First checkpoint of the Chrome-extension capture path ([plan](../.docs/) · #6). Adds
the ingestion seam the localhost endpoint will call, ahead of the server itself.

## Summary
`DirectInputReader.remoteInput(imageData:provenance:into:)` — a thin, DRY wrapper
turning caller-fetched bytes + a fully-populated `SourceDraft` into an `IngestInput`.
Unlike the three local factories (`pasteInput`/`fileInput`/`browserImageInput`) that
*derive* provenance, `remoteInput` takes provenance the caller already built, because
the extension's value is rich per-site provenance (platform, author, title,
`raw_metadata`) extracted in the browser. The app still never downloads — bytes ride
in with the request (007 §scope boundary preserved).

Decision A4 from the #6 interactive review: keep all `IngestInput` construction in one
package rather than building it inline in the (future) server, and rather than
reusing `browserImageInput` (which flattens everything to `platform = .web` + page URL
and discards author/title/platform).

## Files changed
- `AtelierIngestion/Sources/AtelierIngestion/Input/DirectInputReader.swift` — add
  `remoteInput(imageData:provenance:into:)`.
- `AtelierIngestion/Tests/AtelierIngestionTests/DirectInputReaderTests.swift` — add
  `remoteInputProvenance` (asserts the SourceDraft passes through verbatim + bytes
  carried in-memory). Suite: 63 tests.

## Migration notes
None — additive. No change to existing factories, the pipeline, or `AppServices`.
