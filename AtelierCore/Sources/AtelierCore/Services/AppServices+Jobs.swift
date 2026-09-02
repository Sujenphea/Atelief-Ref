// AtelierCore — AppServices: the bulk-import ledger (the P0 file split).
//
// A job, its items, and the known-source set a sweep consults to skip what it has
// already taken (015 · 3A). Moved verbatim out of `AppServices.swift` — same
// code, same order, same comments.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

import Foundation
import GRDB

extension AppServices {

    // MARK: - Bulk-import jobs (015 · decision 3A ledger)

    /// Open a new bulk-import sweep. The service owns `id` / `createdAt` /
    /// `updatedAt` and starts the sweep `open` with a zero `ingestedCount`. The
    /// extension tags each subsequent item POST with the returned id.
    @discardableResult
    public func createJob(
        platform: Platform, scope: String? = nil, totalEstimate: Int? = nil
    ) async throws -> Job {
        let now = Date()
        let job = Job(
            id: UUID(), platform: platform, scope: scope, status: .open,
            totalEstimate: totalEstimate, ingestedCount: 0,
            createdAt: now, updatedAt: now)
        return try await write { db in
            try job.insert(db)
            return job
        }
    }

    /// Record (or re-record) one enumerated item's outcome, in ONE transaction
    /// (P15). Upsert on the `(job_id, source_id)` PK makes a retried record
    /// idempotent — the resumable-sweep invariant. In the SAME transaction the
    /// job's `ingested_count` is RECOMPUTED from the `job_item` rows (not
    /// incremented), so a crash between items leaves the counter exactly
    /// consistent with the committed items — no drift, ever (7A/11A). `.notFound`
    /// if the job is absent.
    @discardableResult
    public func recordJobItem(
        jobID: UUID, sourceID: String, sourceURL: String? = nil,
        status: JobItemStatus, blobHash: String? = nil
    ) async throws -> JobItem {
        let now = Date()
        let item = JobItem(
            jobID: jobID, sourceID: sourceID, sourceURL: sourceURL,
            status: status, blobHash: blobHash, updatedAt: now)
        return try await write { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            // Upsert by composite PK (explicit over clever — matches the codebase's
            // fetch-then-insert/update idiom rather than relying on save() semantics).
            let exists = try JobItem
                .filter(Column("job_id") == Self.key(jobID))
                .filter(Column("source_id") == sourceID)
                .fetchCount(db) > 0
            if exists { try item.update(db) } else { try item.insert(db) }

            // Recompute the denormalized progress counter from the source of truth
            // in the same transaction (no drift on crash / re-record).
            let landed = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM job_item WHERE job_id = ? AND status IN (?, ?)
                """, arguments: [
                    Self.key(jobID),
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ]) ?? 0
            try db.execute(
                sql: "UPDATE job SET ingested_count = ?, updated_at = ? WHERE id = ?",
                arguments: [landed, now, Self.key(jobID)])
            return item
        }
    }

    /// The set of platform source ids already ingested for this job's platform,
    /// across ALL jobs (P14 download-skip). A source is "known" (its bytes are in
    /// the store, so the extension must NOT re-download it) only when some
    /// `job_item` for the SAME platform reached `ingested` or `deduped` — a
    /// `retryableFailed`/`permanentFailed`/`skipped` item is not itself proof the
    /// bytes exist. Scoped by platform so a tweet id can never mask a pin id.
    /// `.notFound` if the job is absent. Content-addressing remains the
    /// authoritative dedup backstop; this only avoids the costly re-download.
    public func knownSourceIDs(forJob jobID: UUID) async throws -> Set<String> {
        try await read { db in
            guard let platform = try String.fetchOne(
                db, sql: "SELECT platform FROM job WHERE id = ?",
                arguments: [Self.key(jobID)]) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return try String.fetchSet(db, sql: """
                SELECT DISTINCT job_item.source_id
                FROM job_item
                JOIN job ON job.id = job_item.job_id
                WHERE job.platform = ? AND job_item.status IN (?, ?)
                """, arguments: [
                    platform,
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ])
        }
    }

    /// Transition a job's lifecycle (7A) — e.g. `.complete` at the cursor
    /// terminator, `.paused` on a user pause, `.halted` on a fatal auth /
    /// rate-limit wall. Bumps `updatedAt`. `.notFound` if the job is absent.
    public func setJobStatus(jobID: UUID, to status: JobStatus) async throws {
        try await write { db in
            var job = try Self.require(Job.self, db: db, key: jobID)
            job.status = status
            job.updatedAt = Date()
            try job.update(db)
        }
    }

    /// Pause every `open` sweep whose last activity (`updatedAt`) is older than
    /// `seconds` before `now`. A browser sweep whose tab/worker dies can no longer
    /// send its own close, so its job would otherwise linger forever as a phantom
    /// "running" entry; this reconciles it to `paused` (resumable). `seconds == 0`
    /// pauses ALL open jobs — used at launch, when no sweep can possibly be running.
    /// Staleness check and pause run in one write transaction (G9). `now` is
    /// injected for deterministic tests.
    @discardableResult
    public func pauseStaleOpenJobs(olderThan seconds: TimeInterval, now: Date) async throws -> [UUID] {
        let cutoff = now.addingTimeInterval(-seconds)
        // Single write transaction: filter + mutate together so a job touched in
        // the gap between a prior read and write is not wrongly paused (G9).
        return try await write { db in
            let stale = try Job
                .filter(Column("status") == JobStatus.open.rawValue)
                .filter(Column("updated_at") <= cutoff)
                .fetchAll(db)
            guard !stale.isEmpty else { return [] }
            var paused: [UUID] = []
            for var job in stale {
                job.status = .paused
                job.updatedAt = now
                try job.update(db)
                paused.append(job.id)
            }
            return paused
        }
    }

    /// Proactive GC of the `known ⟺ blob present` invariant. `deleteAssets` forgets a
    /// blob's ledger rows the instant it orphans, but an asset removed by any OTHER
    /// path (a delete predating the forget feature, a future non-`deleteAssets` caller)
    /// strands its `job_item` as stale-"known" — and a later sweep would then
    /// dedup-skip that source forever despite the bytes being gone, so it never
    /// re-imports. This sweeps every `job_item` whose blob has no backing asset,
    /// forgets it, and recomputes the affected jobs' counts. Check + delete run in
    /// ONE write transaction so a concurrent ingest can't be wrongly pruned (G9).
    /// Returns the job ids reconciled.
    @discardableResult
    public func reconcileOrphanedKnownItems() async throws -> [UUID] {
        try await write { db in
            let orphanedHashes = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_hash FROM job_item
                 WHERE blob_hash IS NOT NULL
                   AND NOT EXISTS (
                     SELECT 1 FROM asset WHERE asset.blob_hash = job_item.blob_hash)
                """)
            guard !orphanedHashes.isEmpty else { return [] }
            let touched = try Self.forgetOrphanedKnownItems(orphanedHashes, in: db)
            return touched.compactMap { UUID(uuidString: $0) }
        }
    }

    /// One job by id (progress UI). `.notFound` if absent. Read.
    public func getJob(id: UUID) async throws -> Job {
        try await read { db in
            let job = try Self.require(Job.self, db: db, key: id)
            return job
        }
    }

    /// A job's items, ordered by `source_id` (stable). `.notFound` if the job is
    /// absent. Read — for progress detail (skipped/failed/dedup breakdown).
    public func jobItems(forJob jobID: UUID) async throws -> [JobItem] {
        try await read { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return try JobItem
                .filter(Column("job_id") == Self.key(jobID))
                .order(Column("source_id"))
                .fetchAll(db)
        }
    }

    /// All jobs, newest first (the progress UI's list). Read.
    public func listJobs() async throws -> [Job] {
        try await read { db in
            try Job.order(Column("created_at").desc, Column("id")).fetchAll(db)
        }
    }

    /// A job's per-outcome item tally (the progress breakdown: ingested / deduped /
    /// skipped / retryable / permanent). Aggregated in SQL (a `GROUP BY`, not by
    /// loading every row) so a large sweep's progress reads stay cheap. A status
    /// with no items is absent from the map (callers default to 0). `.notFound` if
    /// the job is absent. Read.
    public func jobItemCounts(forJob jobID: UUID) async throws -> [JobItemStatus: Int] {
        try await read { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT status, count(*) AS n FROM job_item WHERE job_id = ? GROUP BY status
                """, arguments: [Self.key(jobID)])
            var counts: [JobItemStatus: Int] = [:]
            for row in rows {
                if let status = JobItemStatus(rawValue: row["status"]) {
                    counts[status] = row["n"]
                }
            }
            return counts
        }
    }

    /// A job's current lifecycle status (the relay feedback the extension polls per
    /// item to honour an app-side pause/cancel — 7A). `.notFound` if absent. Read.
    public func jobStatus(forJob jobID: UUID) async throws -> JobStatus {
        try await read { db in
            guard let raw = try String.fetchOne(
                db, sql: "SELECT status FROM job WHERE id = ?", arguments: [Self.key(jobID)]),
                let status = JobStatus(rawValue: raw) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return status
        }
    }
}
