# 018 — Ingestion: Pipeline + coordinator

**Chunk 4** of the ingestion build: the piece that ties everything together —
the single-image ingestion PIPELINE (bytes → stored blob + thumbnails →
persisted asset) and the bounded-concurrency batch COORDINATOR (off-main,
partial-failure-tolerant, cancellable, with progress). Builds directly on the
chunk-2 `MediaStore` (atomic writes), the chunk-3 imaging utilities (hash /
metadata / thumbnails), and the `AtelierCore` `AppServices.ingest` seam.

## Summary

### `IngestError` (C8)
`public enum IngestError: Error, Equatable` naming the pipeline STAGE that
failed: `.unreadableSource`, `.unsupportedType(mime:)`, `.decodeFailed`,
`.thumbnailFailed`, `.blobWriteFailed`, `.persistence(AtelierError)`. An internal
`init(mapping error:)` folds lower-level errors into the matching stage:
`ImageError.unreadable → .unreadableSource`, `.unsupportedType → .unsupportedType`,
`.decodeFailed → .decodeFailed`, `.thumbnailFailed → .thumbnailFailed`;
`AtelierError → .persistence`; an existing `IngestError` passes through; anything
else (raw file-IO) → `.blobWriteFailed`.

### `IngestInput` / `IngestOutcome`
- `public enum ByteSource: Sendable { case data(Data); case fileURL(URL) }`.
- `public struct IngestInput: Sendable` — `source`, `provenance` (a required
  `SourceDraft`, C6), `collectionID`, optional `placement`. The caller (chunk 5
  adapters) supplies bytes + populated provenance + target collection.
- `public enum IngestOutcome: Sendable { case ingested(asset: Asset,
  deduplicated: Bool); case failed(IngestError) }` — one per input, index-aligned.

### `IngestPipeline` (A2 + P14)
`public struct IngestPipeline: Sendable` over a `MediaStore`, an `AppServices`,
and the thumbnail tiers (default `ThumbnailTier.allCases`).
`func ingest(_ input:) async -> IngestOutcome` NEVER throws — the whole body is a
`do/catch` that converts any thrown error via `IngestError(mapping:)`. Stages:
1. obtain bytes (`.data` as-is; `.fileURL` read now, read failure →
   `.unreadableSource`);
2. `ContentHasher.hash(bytes)`;
3. `ImageMetadata.extract(from:)` (throws → decode/unsupported/unreadable);
4. **blob-first (A2) + hash-first short-circuit (P14)** — store the blob only if
   `!hasBlob`, then generate + store ONLY the tiers where `!hasThumbnail`;
5. persist in ONE transaction (P15) via `AppServices.ingest` with an `AssetDraft`
   (`downloadState: .downloaded`, `fileSize: bytes.count`);
6. return `.ingested(asset:, deduplicated: result.wasDeduplicated)`.

### `IngestCoordinator` (A3)
- Internal free function `func runBounded<T: Sendable>(_ items: [IngestInput],
  maxConcurrent:, _ operation:) async -> [T]` — the reusable bounded-concurrency
  core, testable in isolation.
- `public actor IngestCoordinator` over an `IngestPipeline` + `maxConcurrent`
  (default 4). `func ingest(_ inputs:, onProgress:) async -> [IngestOutcome]`
  runs `pipeline.ingest` through `runBounded`, reporting monotonic progress and
  returning outcomes in input order.

## How `runBounded` caps in-flight tasks
The `withTaskGroup` is PRIMED with exactly `maxConcurrent` child tasks, then runs
strictly one-in-one-out: each `group.next()` completion launches AT MOST one
replacement. The group therefore never holds more than `maxConcurrent` unfinished
children. Results are keyed by input index and compacted back into input order.
Cancellation-aware: the `!Task.isCancelled` guard stops launching NEW work while
already-launched items drain (MediaStore atomicity ⇒ they finish complete). The
concurrency test probes this by calling `runBounded` directly with a probe op
that `enter`/`leave`s an actor tracking peak live concurrency and asserts
`maxSeen <= maxConcurrent` for a 40-item batch at limit 3.

## How P14 short-circuit + A2 blob-first ordering work
`ingest` hashes FIRST, then writes the blob only when `!store.hasBlob(...)` and
generates each tier only when `!store.hasThumbnail(...)`. A fully-present
blob+tiers does ZERO decode/thumbnail work — only the DB row + membership are
ensured; a purged tier is regenerated individually. The blob (and its tiers) are
durable on disk (atomic rename) BEFORE `AppServices.ingest` writes the row, so no
asset row can ever reference a missing blob (A2). A crash between the two leaves
only a harmless orphan blob.

## Progress delivery
A private `ProgressReporter` actor increments the completed count AND invokes
`onProgress` under its own isolation, so deliveries are a strictly ordered
1…total sequence — never reordered by out-of-order task completion.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestError.swift` *(new)*
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestInput.swift` *(new)*
  — `ByteSource`, `IngestInput`, `IngestOutcome`.
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestPipeline.swift` *(new)*
- `AtelierIngestion/Sources/AtelierIngestion/Pipeline/IngestCoordinator.swift`
  *(new)* — `runBounded` + `IngestCoordinator` + private `ProgressReporter`.
- `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/TempLibrary.swift`
  *(extended)* — `TempPipeline` (`MediaStore` + real `AppServices` + a created
  collection + wired `IngestPipeline`/`IngestCoordinator`) via
  `makeTempPipeline(maxConcurrent:)`, plus `blobFiles()` / `thumbnailFiles()` /
  `cacheFiles()` enumeration helpers; imports `AtelierCore`.
- `AtelierIngestion/Tests/AtelierIngestionTests/IngestPipelineTests.swift` *(new)*
  — end-to-end, A2 invariant, P14 dedup + purge-regeneration, C8 failure mapping,
  file-URL input.
- `AtelierIngestion/Tests/AtelierIngestionTests/IngestCoordinatorTests.swift`
  *(new, T12)* — mixed-batch not-aborted, bounded-concurrency probe, cancellation
  leaves only complete/valid blobs, monotonic progress, end-to-end 3-image batch.

## Verification

- `cd AtelierIngestion && swift test` — **50 tests in 7 suites passed**, ~0.6s
  (14 new pipeline/coordinator tests across `IngestPipeline`/`IngestCoordinator`,
  plus the chunk 1–3 suites).
- Cancellation test verifies COMPLETENESS structurally: every file under `blobs/`
  is re-read and its bytes re-hashed, asserting the digest equals the hash in the
  filename, and `cache/` has no leftover staging temp files.

## Notes

- `runBounded`'s return is in input order but MAY be shorter than the input when a
  batch is cancelled partway (only completed items appear) — the coordinator's
  primary contract on cancel is "no partial blobs", which MediaStore atomicity
  guarantees.
- The probe operation for the concurrency test ignores its `IngestInput` (passes
  a dummy `.data(Data())`), so `runBounded`'s cap is exercised without touching
  the filesystem or DB.

## Migration notes

None — additive. New public surface in `AtelierIngestion` (`IngestError`,
`ByteSource`, `IngestInput`, `IngestOutcome`, `IngestPipeline`,
`IngestCoordinator`). Not yet wired into the app — chunk 5 adds the paste / drag
/ browser input adapters and the app drop-target that drive the coordinator.
