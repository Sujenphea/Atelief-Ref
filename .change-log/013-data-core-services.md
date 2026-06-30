# 013 — Data core: App Services write funnel

**Chunk 5** of the data-core build: the public App Services mutation path — the
single write funnel, typed errors, centralized validation, the dedup-aware
`ingest`, and bulk arrange operations. This is the package's only public surface
(A2); reads/search are chunk 6.

## Summary

`AppServices` is a `public final class … Sendable` over the internal
`LibraryDatabase`. Every mutation routes through one private `write {}` funnel
(A4) that runs the op in the pool's serialized writer transaction and maps any
thrown error to an `AtelierError` (C7), so GRDB never crosses the public
boundary. Provenance is unrepresentable-illegal: `ingest` takes a non-optional
`SourceDraft` (C6). Validation runs before any row is written (C8).

## Decisions realized

- **A2/A4** — `AppServices` is the sole public type; one private `write {}`
  funnel; `LibraryDatabase`, records, migrator stay internal.
- **A3** — methods are `async`, serialized by the `DatabasePool` writer (WAL).
- **C6** — `ingest(_:from:into:)` requires a `SourceDraft` parameter; there is no
  public "insert bare Asset" path. The service generates `id` + timestamps
  (server-authoritative); drafts carry only caller-supplied provenance facts.
- **C7** — `AtelierError` (public, explicit cases) + an internal `init(mapping:)`
  collapsing GRDB `DatabaseError` to `.constraintViolation` / `.persistenceFailure`.
- **C8** — `Validation` helpers (name, dimensions, fileSize, blobHash, canvas
  placement finite/positive, per-platform originalURL) run before the write.
- **P15** — `setGridOrder` / `addAssets` / `removeAssets` each run in ONE
  transaction (one fsync under WAL); a `.notFound` mid-batch rolls the whole
  batch back.
- **18A dedup** — `ingest` reuses an existing asset (and its source) sharing the
  `blob_hash` whose source matches the incoming provenance (same `original_url`,
  or same `platform` when no URL); otherwise inserts a new source + asset sharing
  the hash. Idempotent on membership, so re-ingesting identical bytes+provenance
  into the same collection is a total no-op.

## Public surface

- Collections: `createCollection`, `renameCollection`, `setCollectionCover`,
  `deleteCollection`.
- Ingest: `ingest(_: AssetDraft, from: SourceDraft, into:, placement:) -> IngestResult`.
- Arrange/bulk: `setCanvasPlacement`, `setGridOrder`, `addAssets`, `removeAssets`.
- Value types: `AssetDraft`, `SourceDraft`, `CanvasPlacement`, `IngestResult`,
  `AtelierError` — all GRDB-free.

## Files changed

- `Services/AppServices.swift` *(new)* — the public class + the write funnel + all
  mutation methods + private dedup/membership query helpers.
- `Services/AtelierError.swift` *(new)* — typed errors + GRDB mapping.
- `Services/Validation.swift` *(new)* — the C8 rules.
- `Services/ServiceTypes.swift` *(new)* — drafts, placement, result.
- `Tests/AtelierCoreTests/ServicesValidationTests.swift` *(new)* — every
  validation rule (incl. the NaN/inf placement class).
- `Tests/AtelierCoreTests/ServicesInvariantTests.swift` *(new, T11)* — provenance,
  18A dedup (identical no-op / distinct provenance / across collections / local
  by platform), many-to-many, cascade through the surface, every error trigger,
  the GRDB→AtelierError mapping.
- `Tests/AtelierCoreTests/ServicesConcurrencyTests.swift` *(new, T12)* — concurrent
  writes+reads never lock; the concurrent identical-ingest race resolves to ONE
  asset.

## Verification

- `swift test` — **102 tests in 20 suites pass** (chunks 1-4 included).
- GRDB does not leak: the public API (`AppServices`, `AtelierError`, drafts) is
  GRDB-free.

## Migration notes

None — additive. `import AtelierCore` now exposes the `AppServices` mutation
path. Reads/search (the public query API + FTS5) land in chunk 6. Note: this
chunk was completed by the orchestrator after the build agent's connection
dropped mid-task — the four implementation files were the agent's; the three
test suites + this changelog were written and verified by the orchestrator.
