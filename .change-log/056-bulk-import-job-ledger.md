# 056 — Bulk import: job ledger (Phase 1)

Phase 1 of the bulk-import feature ([.docs/015–018](../.docs/015-bulk-import-overview.md)):
the app-side durable job ledger + the `/jobs` handshake that wraps the unchanged
per-item ingest hot path. Decisions 3A / 7A / 8A / 11A / P14 / P15.

## Summary

- **AtelierCore v3 schema** — new `job` and `job_item` tables. `job_item` is
  composite-PK'd by `(job_id, source_id)` (upsert = idempotent re-record) with an
  `ON DELETE CASCADE` FK to `job`; indexed on `source_id` (the O(1) download-skip
  lookup, P14) and `job.platform`.
- **Domain** — `Job` / `JobItem` value types + `JobStatus`
  (`open`/`paused`/`complete`/`halted`) and `JobItemStatus`
  (`ingested`/`deduped`/`skipped`/`retryable_failed`/`permanent_failed`, the 7A
  taxonomy).
- **AppServices** — `createJob`, `recordJobItem` (upsert + `ingested_count`
  RECOMPUTED in the same transaction — no drift on crash/re-record, 11A),
  `knownSourceIDs(forJob:)` (platform-scoped landed set for P14),
  `setJobStatus`, `getJob`, `jobItems`. `AppServices` conforms to the server's
  `JobLedger` seam verbatim.
- **AtelierServer** — `POST /jobs` (→ `201` + `{jobId, caps}`; the server surfaces
  its own body/video caps at open, 8A), `GET /jobs/{id}/known-sources`,
  `POST /jobs/{id}/complete`. `CaptureRequest`/`VideoCaptureHeader` gain optional
  `jobId`+`sourceId`; a tagged capture records a `job_item` (best-effort) mapping
  the ingest outcome to the item taxonomy. All `/jobs` routes go through the
  existing `CaptureAuth` (token + Origin); CORS allow-methods gains `GET`.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/Job.swift` (new)
- `AtelierCore/Sources/AtelierCore/Persistence/Job+GRDB.swift` (new)
- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` (v3)
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` (job methods)
- `AtelierServer/Sources/AtelierServer/JobDTO.swift` (new — DTOs + `JobLedger`)
- `AtelierServer/Sources/AtelierServer/JobRoutes.swift` (new)
- `AtelierServer/Sources/AtelierServer/CaptureDTO.swift` (jobId/sourceId tags)
- `AtelierServer/Sources/AtelierServer/CaptureRoutes.swift` (ledger recording)
- `AtelierServer/Sources/AtelierServer/CaptureServer.swift` (`/jobs` dispatch)
- `AtelierServer/Sources/AtelierServer/CaptureAuth.swift` (CORS GET)
- Tests: `ServicesJobTests`, v3 suites in `MigrationTests`, `JobRoutesTests`,
  `JobServerIntegrationTests`; updated the pinned migration list + CORS assertion.

## Verification

`swift test` green: AtelierCore 181 tests, AtelierServer 67 tests. Covers the
crash-consistency invariant (count exactly tracks landed items after each record),
idempotent re-record, platform-scoped known-sources, concurrent tagged POSTs over
the socket (no lost updates), and the full auth/404/400 matrix.

## Migration notes

- v3 is append-only (never edit the shipped body). Existing libraries migrate
  forward on next open; no data touched in v1/v2 tables.
- The single-item capture wire is unchanged (`jobId`/`sourceId` are optional).

## App wiring

`AtelierRefs/IngestionModel.swift:startCaptureEndpoint` now constructs
`JobRoutes(ledger: services, caps:)` and passes `jobLedger: services` to
`CaptureRoutes`, so the running app serves `/jobs` and records `job_item`s for
tagged captures. Verified: `xcodebuild -scheme AtelierRefs` BUILD SUCCEEDED
(the package integration tests already exercise this exact server + ledger stack
over a real socket).

## Next steps

- Extension-side bulk engine + drivers (Phases 2–6) consume this endpoint.
