// AtelierCore — App Services bulk-import job tests (015 · decision 3A / 11A)
//
// The durable job ledger: create/open a sweep, record per-item outcomes with an
// idempotent upsert, keep `ingested_count` exactly consistent with the committed
// items (the crash-consistency invariant — 11A), answer the platform-scoped
// download-skip set (P14), and drive status transitions. House style mirrors
// `ServicesFolderTests` — temp DB fixture, async `#expect(throws:)`.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: bulk-import jobs (3A ledger)")
struct ServicesJobTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    // MARK: create

    @Test("createJob opens an empty sweep the service stamps")
    func createJobDefaults() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(
            platform: .pinterest, scope: "board:1", totalEstimate: 100)
        #expect(job.platform == .pinterest)
        #expect(job.scope == "board:1")
        #expect(job.status == .open)
        #expect(job.totalEstimate == 100)
        #expect(job.ingestedCount == 0)
        // Persisted + fetchable. Compare the stable fields (not the whole struct):
        // the service stamps createdAt/updatedAt with `Date()`, whose sub-millisecond
        // precision is truncated by SQLite's millisecond text — exact date round-trip
        // is covered by JobRoundTripTests with millisecond-exact fixtures.
        let fetched = try await services.getJob(id: job.id)
        #expect(fetched.id == job.id)
        #expect(fetched.platform == job.platform)
        #expect(fetched.scope == job.scope)
        #expect(fetched.status == job.status)
        #expect(fetched.totalEstimate == job.totalEstimate)
        #expect(fetched.ingestedCount == 0)
    }

    // MARK: recordJobItem + ingested_count invariant

    @Test("recording an ingested item bumps ingested_count; skipped/failed do not")
    func countReflectsLandedOnly() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .twitter)

        try await services.recordJobItem(jobID: job.id, sourceID: "t1", status: .ingested, blobHash: "h1")
        #expect(try await services.getJob(id: job.id).ingestedCount == 1)

        try await services.recordJobItem(jobID: job.id, sourceID: "t2", status: .deduped, blobHash: "h2")
        #expect(try await services.getJob(id: job.id).ingestedCount == 2)

        // Neither a skip nor a failure counts as "landed".
        try await services.recordJobItem(jobID: job.id, sourceID: "t3", status: .skipped)
        try await services.recordJobItem(jobID: job.id, sourceID: "t4", status: .retryableFailed)
        try await services.recordJobItem(jobID: job.id, sourceID: "t5", status: .permanentFailed)
        #expect(try await services.getJob(id: job.id).ingestedCount == 2)
    }

    @Test("re-recording the same (job,source) upserts and never double-counts (idempotent)")
    func upsertIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .pinterest)

        // Same source recorded twice as ingested — one row, one count.
        try await services.recordJobItem(jobID: job.id, sourceID: "p1", status: .ingested, blobHash: "h1")
        try await services.recordJobItem(jobID: job.id, sourceID: "p1", status: .ingested, blobHash: "h1")
        #expect(try await services.getJob(id: job.id).ingestedCount == 1)
        #expect(try await services.jobItems(forJob: job.id).count == 1)

        // A status transition on the same key updates in place (still one row);
        // moving ingested -> retryableFailed drops it out of the landed count.
        try await services.recordJobItem(jobID: job.id, sourceID: "p1", status: .retryableFailed)
        #expect(try await services.jobItems(forJob: job.id).count == 1)
        #expect(try await services.getJob(id: job.id).ingestedCount == 0)
    }

    @Test("ingested_count stays exactly consistent after each record (crash-consistency invariant)")
    func countConsistentAfterEachRecord() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .twitter)
        // Each recordJobItem is its own transaction; after each one the
        // denormalized counter must equal the count of landed items, so any crash
        // between items leaves a consistent, resumable ledger (11A).
        let plan: [(String, JobItemStatus)] = [
            ("a", .ingested), ("b", .skipped), ("c", .deduped),
            ("d", .permanentFailed), ("e", .ingested), ("f", .retryableFailed),
        ]
        for (source, status) in plan {
            try await services.recordJobItem(jobID: job.id, sourceID: source, status: status)
            let items = try await services.jobItems(forJob: job.id)
            let landed = items.filter { $0.status == .ingested || $0.status == .deduped }.count
            #expect(try await services.getJob(id: job.id).ingestedCount == landed)
        }
        #expect(try await services.getJob(id: job.id).ingestedCount == 3) // a, c, e
    }

    // MARK: knownSourceIDs (P14 download-skip)

    @Test("knownSourceIDs returns landed sources only, scoped to the job's platform")
    func knownSourcesLandedAndScoped() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let pin = try await services.createJob(platform: .pinterest, scope: "board:1")
        let tweet = try await services.createJob(platform: .twitter)

        try await services.recordJobItem(jobID: pin.id, sourceID: "pin-A", status: .ingested, blobHash: "h1")
        try await services.recordJobItem(jobID: pin.id, sourceID: "pin-B", status: .deduped, blobHash: "h2")
        try await services.recordJobItem(jobID: pin.id, sourceID: "pin-C", status: .skipped)           // not landed
        try await services.recordJobItem(jobID: pin.id, sourceID: "pin-D", status: .permanentFailed)   // not landed
        try await services.recordJobItem(jobID: tweet.id, sourceID: "tw-A", status: .ingested, blobHash: "h3")

        let pinKnown = try await services.knownSourceIDs(forJob: pin.id)
        #expect(pinKnown == ["pin-A", "pin-B"])
        // Platform scoping: the twitter landing never leaks into pinterest's set,
        // and vice versa.
        #expect(!pinKnown.contains("tw-A"))
        let tweetKnown = try await services.knownSourceIDs(forJob: tweet.id)
        #expect(tweetKnown == ["tw-A"])
    }

    @Test("knownSourceIDs unions landed sources across multiple jobs of a platform")
    func knownSourcesUnionAcrossJobs() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let first = try await services.createJob(platform: .pinterest, scope: "board:1")
        try await services.recordJobItem(jobID: first.id, sourceID: "pin-A", status: .ingested, blobHash: "h1")
        // A fresh sweep of the same platform sees the prior sweep's landings, so
        // it can skip re-downloading them (P14).
        let second = try await services.createJob(platform: .pinterest, scope: "board:2")
        let known = try await services.knownSourceIDs(forJob: second.id)
        #expect(known == ["pin-A"])
    }

    // MARK: status transitions

    @Test("setJobStatus transitions the lifecycle and bumps updatedAt")
    func statusTransitions() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .twitter)
        try await services.setJobStatus(jobID: job.id, to: .halted)
        let halted = try await services.getJob(id: job.id)
        #expect(halted.status == .halted)
        #expect(halted.updatedAt >= job.updatedAt)
        try await services.setJobStatus(jobID: job.id, to: .complete)
        #expect(try await services.getJob(id: job.id).status == .complete)
    }

    @Test("jobItems are ordered by source_id")
    func jobItemsOrdered() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .pinterest)
        for s in ["c", "a", "b"] {
            try await services.recordJobItem(jobID: job.id, sourceID: s, status: .ingested, blobHash: "h")
        }
        let items = try await services.jobItems(forJob: job.id)
        #expect(items.map(\.sourceID) == ["a", "b", "c"])
    }

    @Test("listJobs returns every job, newest first")
    func listJobsNewestFirst() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let first = try await services.createJob(platform: .pinterest)
        let second = try await services.createJob(platform: .twitter)
        let jobs = try await services.listJobs()
        #expect(jobs.count == 2)
        // created_at desc — the later-created job leads (tie broken by id).
        #expect(Set(jobs.map(\.id)) == [first.id, second.id])
        #expect(jobs.first?.createdAt ?? .distantPast >= jobs.last?.createdAt ?? .distantFuture)
    }

    @Test("jobItemCounts tallies each outcome via GROUP BY")
    func itemCountsByStatus() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(jobID: job.id, sourceID: "a", status: .ingested, blobHash: "h")
        try await services.recordJobItem(jobID: job.id, sourceID: "b", status: .ingested, blobHash: "h")
        try await services.recordJobItem(jobID: job.id, sourceID: "c", status: .deduped, blobHash: "h")
        try await services.recordJobItem(jobID: job.id, sourceID: "d", status: .permanentFailed)

        let counts = try await services.jobItemCounts(forJob: job.id)
        #expect(counts[.ingested] == 2)
        #expect(counts[.deduped] == 1)
        #expect(counts[.permanentFailed] == 1)
        #expect(counts[.skipped] == nil) // absent status → not in the map
    }

    @Test("jobStatus reads the current lifecycle status (relay feedback)")
    func jobStatusReads() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .twitter)
        #expect(try await services.jobStatus(forJob: job.id) == .open)
        try await services.setJobStatus(jobID: job.id, to: .paused)
        #expect(try await services.jobStatus(forJob: job.id) == .paused)
    }

    // MARK: pauseStaleOpenJobs (abandoned-sweep reconcile)

    @Test("pauseStaleOpenJobs(olderThan: 0) pauses every open sweep, sparing closed ones")
    func reconcileAllOpenAtLaunch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let open1 = try await services.createJob(platform: .pinterest, scope: "board:1")
        let open2 = try await services.createJob(platform: .twitter)
        let done = try await services.createJob(platform: .pinterest)
        try await services.setJobStatus(jobID: done.id, to: .complete)

        // At launch nothing can be running → every open job is abandoned.
        let changed = try await services.pauseStaleOpenJobs(olderThan: 0, now: Date())
        #expect(Set(changed) == Set([open1.id, open2.id]))

        let byID = Dictionary(uniqueKeysWithValues: try await services.listJobs().map { ($0.id, $0) })
        #expect(byID[open1.id]?.status == .paused)
        #expect(byID[open2.id]?.status == .paused)
        #expect(byID[done.id]?.status == .complete)   // a closed job is never touched
    }

    @Test("pauseStaleOpenJobs spares a recently-active open sweep, pauses a stalled one")
    func reconcileByAge() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .pinterest)
        let t0 = try #require(try await services.listJobs().first { $0.id == job.id }).updatedAt

        // 10s of inactivity, threshold 90 → still active, spared (no write).
        let spared = try await services.pauseStaleOpenJobs(olderThan: 90, now: t0.addingTimeInterval(10))
        #expect(spared.isEmpty)
        #expect(try await services.jobStatus(forJob: job.id) == .open)

        // 200s of inactivity → past the threshold → paused (resumable).
        let paused = try await services.pauseStaleOpenJobs(olderThan: 90, now: t0.addingTimeInterval(200))
        #expect(paused == [job.id])
        #expect(try await services.jobStatus(forJob: job.id) == .paused)
    }

    @Test("pauseStaleOpenJobs is a no-op (no rows changed) when nothing is open")
    func reconcileNoop() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .pinterest)
        try await services.setJobStatus(jobID: job.id, to: .complete)
        let changed = try await services.pauseStaleOpenJobs(olderThan: 0, now: Date())
        #expect(changed.isEmpty)
        #expect(try await services.jobStatus(forJob: job.id) == .complete)
    }

    // MARK: clear log

    @Test("clearFinishedJobs hides the terminal sweeps and leaves the live ones")
    func clearHidesOnlyFinished() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let running = try await services.createJob(platform: .pinterest)
        let paused = try await services.createJob(platform: .pinterest)
        let done = try await services.createJob(platform: .twitter)
        let stopped = try await services.createJob(platform: .twitter)
        try await services.setJobStatus(jobID: paused.id, to: .paused)
        try await services.setJobStatus(jobID: done.id, to: .complete)
        try await services.setJobStatus(jobID: stopped.id, to: .halted)

        let cleared = try await services.clearFinishedJobs()

        #expect(cleared == 2)
        let listed = try await services.listJobs()
        // A paused sweep that can't be seen can't be resumed — it stays.
        #expect(Set(listed.map(\.id)) == [running.id, paused.id])
    }

    @Test("a cleared sweep keeps its items, so a later sweep still skips them (P14)")
    func clearKeepsTheDownloadSkipSet() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let old = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(
            jobID: old.id, sourceID: "pin-1", status: .ingested, blobHash: "hash")
        try await services.setJobStatus(jobID: old.id, to: .complete)

        try await services.clearFinishedJobs()

        // The cleared job is gone from the LIST but not from the ledger: a new sweep
        // of the same platform still knows pin-1 has landed.
        #expect(try await services.listJobs().isEmpty)
        let next = try await services.createJob(platform: .pinterest)
        #expect(try await services.knownSourceIDs(forJob: next.id) == ["pin-1"])
        #expect(try await services.getJob(id: old.id).clearedAt != nil)
    }

    @Test("clearing again clears nothing — cleared_at is stamped once")
    func clearIsIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let done = try await services.createJob(platform: .pinterest)
        try await services.setJobStatus(jobID: done.id, to: .complete)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(try await services.clearFinishedJobs(now: stamp) == 1)
        #expect(try await services.clearFinishedJobs() == 0)
        let cleared = try await services.getJob(id: done.id).clearedAt
        #expect(cleared.map { abs($0.timeIntervalSince(stamp)) < 0.001 } == true)
    }

    @Test("clearing with nothing finished is a no-op")
    func clearWithNothingFinished() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let running = try await services.createJob(platform: .pinterest)
        #expect(try await services.clearFinishedJobs() == 0)
        #expect(try await services.listJobs().map(\.id) == [running.id])
    }

    // MARK: recordJobProgress (the sweep heartbeat)

    @Test("a ping bumps updated_at, so the staleness reconciler spares a quiet sweep")
    func progressKeepsAnOpenSweepAlive() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .rednote, scope: "board:1")
        let t0 = try await services.getJob(id: job.id).updatedAt

        // 200s into a relay-free stretch (dedup skips / note-opens) the sweep pings. Without
        // it `updated_at` is still `t0` and the 90s reconciler pauses a running sweep.
        _ = try await services.recordJobProgress(
            jobID: job.id, skipped: 12, now: t0.addingTimeInterval(200))

        let spared = try await services.pauseStaleOpenJobs(
            olderThan: 90, now: t0.addingTimeInterval(260))
        #expect(spared.isEmpty)
        #expect(try await services.jobStatus(forJob: job.id) == .open)
    }

    @Test("the skipped count is RAISED, never assigned — a resume cannot walk it back")
    func progressRaisesNeverAssigns() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .rednote)

        _ = try await services.recordJobProgress(jobID: job.id, skipped: 82)
        #expect(try await services.getJob(id: job.id).skippedCount == 82)

        // A resumed sweep reopens the SAME job id with its engine counts back at 0 and
        // re-skips its way to where it stopped. Assigning would make the number fall.
        _ = try await services.recordJobProgress(jobID: job.id, skipped: 0)
        _ = try await services.recordJobProgress(jobID: job.id, skipped: 30)
        #expect(try await services.getJob(id: job.id).skippedCount == 82)

        // Past the high-water mark it climbs again.
        _ = try await services.recordJobProgress(jobID: job.id, skipped: 95)
        #expect(try await services.getJob(id: job.id).skippedCount == 95)
    }

    @Test("a ping never resurrects a job: no status change, and no updated_at bump")
    func progressCannotReopenAClosedJob() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        for closed: JobStatus in [.paused, .halted, .complete] {
            let job = try await services.createJob(platform: .pinterest)
            try await services.setJobStatus(jobID: job.id, to: closed)
            let settled = try await services.getJob(id: job.id).updatedAt

            // A sweep that has not yet noticed it was paused keeps breathing for one more
            // interval. That must not undo the pause, nor make a finished sweep look live.
            let reported = try await services.recordJobProgress(
                jobID: job.id, skipped: 7, now: settled.addingTimeInterval(3600))

            #expect(reported == closed)  // the caller is told which case it was
            let after = try await services.getJob(id: job.id)
            #expect(after.status == closed)
            #expect(after.updatedAt == settled)
            // The count still lands — the skips it reports genuinely happened.
            #expect(after.skippedCount == 7)
        }
    }

    @Test("a ping leaves every other counter alone (it is not an item record)")
    func progressTouchesOnlyItsOwnFields() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let job = try await services.createJob(platform: .twitter, totalEstimate: 40)
        try await services.recordJobItem(jobID: job.id, sourceID: "t1", status: .ingested, blobHash: "h1")

        _ = try await services.recordJobProgress(jobID: job.id, skipped: 5)

        let after = try await services.getJob(id: job.id)
        #expect(after.ingestedCount == 1)        // recomputed from job_item, not from a ping
        #expect(after.totalEstimate == 40)
        #expect(try await services.jobItems(forJob: job.id).count == 1)  // no row was written
    }

    // MARK: not-found paths

    @Test("job operations on an absent job throw notFound")
    func notFoundPaths() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.self) { try await services.getJob(id: ghost) }
        await #expect(throws: AtelierError.self) { try await services.setJobStatus(jobID: ghost, to: .complete) }
        await #expect(throws: AtelierError.self) { try await services.knownSourceIDs(forJob: ghost) }
        await #expect(throws: AtelierError.self) { try await services.jobItems(forJob: ghost) }
        await #expect(throws: AtelierError.self) { try await services.jobItemCounts(forJob: ghost) }
        await #expect(throws: AtelierError.self) { try await services.jobStatus(forJob: ghost) }
        await #expect(throws: AtelierError.self) {
            try await services.recordJobItem(jobID: ghost, sourceID: "x", status: .ingested)
        }
        await #expect(throws: AtelierError.self) {
            try await services.recordJobProgress(jobID: ghost, skipped: 1)
        }
    }
}
