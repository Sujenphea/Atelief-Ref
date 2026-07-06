// AtelierServer — bulk-import job route tests (015 · decision 3A, T11 pure layer).
//
// Two things, no socket:
//   1. `JobRoutes` against a FAKE `JobLedger` — the create/known-sources/complete
//      matrix incl. bad platform/status and the notFound → 404 mapping.
//   2. The ledger-recording SIDE of the ingest hot path: a REAL capture (temp
//      library + coordinator) TAGGED with jobId+sourceId records the right
//      `JobItemStatus` (ingested / deduped / permanentFailed); an untagged capture
//      records nothing.

import Foundation
import Testing

import AtelierCore
import AtelierIngestion
@testable import AtelierServer

/// A recording fake ``JobLedger``. Thread-safe; `knownSourceIDs` / `setJobStatus`
/// throw `AtelierError.notFound` for a job it never "created" (to drive the 404
/// mapping).
final class FakeJobLedger: JobLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var _createdPlatforms: [Platform] = []
    private var _recorded: [(jobID: UUID, sourceID: String, status: JobItemStatus, blobHash: String?)] = []
    private var _statusUpdates: [(jobID: UUID, status: JobStatus)] = []
    private var _known: Set<UUID> = []
    /// The source ids `knownSourceIDs` returns for a known job (settable by a test).
    var knownSources: [String] = []
    /// The status `jobStatus(forJob:)` returns (settable — drives the relay feedback).
    var currentStatus: JobStatus = .open
    /// The id `createJob` returns (so a test can address the created job).
    let createdID = UUID()

    func createJob(platform: Platform, scope: String?, totalEstimate: Int?) async throws -> Job {
        noteCreate(platform)
        return Job(
            id: createdID, platform: platform, scope: scope, totalEstimate: totalEstimate,
            createdAt: Date(), updatedAt: Date())
    }

    @discardableResult
    func recordJobItem(
        jobID: UUID, sourceID: String, sourceURL: String?,
        status: JobItemStatus, blobHash: String?
    ) async throws -> JobItem {
        noteItem((jobID, sourceID, status, blobHash))
        return JobItem(
            jobID: jobID, sourceID: sourceID, sourceURL: sourceURL,
            status: status, blobHash: blobHash, updatedAt: Date())
    }

    func knownSourceIDs(forJob jobID: UUID) async throws -> Set<String> {
        try requireKnown(jobID)
        return Set(knownSources)
    }

    func setJobStatus(jobID: UUID, to status: JobStatus) async throws {
        try requireKnown(jobID)
        noteStatus((jobID, status))
    }

    func jobStatus(forJob jobID: UUID) async throws -> JobStatus {
        try requireKnown(jobID)   // realistic: the real ledger throws .notFound
        return currentStatus
    }

    /// Register an already-existing job (task-8 reopen tests) without a `createJob`
    /// call, so a test can distinguish "reopened an existing job" from "minted a new
    /// one" (the latter shows up in `createdPlatforms`).
    func seedExisting(_ id: UUID) {
        lock.lock(); _known.insert(id); lock.unlock()
    }

    // Synchronous locked mutators — NSLock's lock/unlock are unavailable from an
    // async context, so the async methods above delegate the mutation here.
    private func noteCreate(_ platform: Platform) {
        lock.lock(); _createdPlatforms.append(platform); _known.insert(createdID); lock.unlock()
    }
    private func noteItem(_ item: (jobID: UUID, sourceID: String, status: JobItemStatus, blobHash: String?)) {
        lock.lock(); _recorded.append(item); lock.unlock()
    }
    private func noteStatus(_ update: (jobID: UUID, status: JobStatus)) {
        lock.lock(); _statusUpdates.append(update); lock.unlock()
    }

    private func requireKnown(_ jobID: UUID) throws {
        lock.lock(); let known = _known.contains(jobID); lock.unlock()
        if !known { throw AtelierError.notFound(entity: "job", id: jobID) }
    }

    // Read accessors (under lock).
    var createdPlatforms: [Platform] { lock.lock(); defer { lock.unlock() }; return _createdPlatforms }
    var recorded: [(jobID: UUID, sourceID: String, status: JobItemStatus, blobHash: String?)] {
        lock.lock(); defer { lock.unlock() }; return _recorded
    }
    var statusUpdates: [(jobID: UUID, status: JobStatus)] { lock.lock(); defer { lock.unlock() }; return _statusUpdates }
}

@Suite("JobRoutes (pure, fake ledger)")
struct JobRoutesFakeTests {
    private let caps = CapsDTO(maxBodyBytes: 111, maxVideoBodyBytes: 222)
    private func routes(_ ledger: JobLedger, consent: Bool = true) -> JobRoutes {
        JobRoutes(ledger: ledger, caps: caps, consentGranted: { consent })
    }

    private func body(_ value: Encodable) -> Data { try! JSONEncoder().encode(value) }

    @Test("POST /jobs valid → 201 created with jobId + the server's caps")
    func createValid() async throws {
        let fake = FakeJobLedger()
        let result = await routes(fake).handleCreateJob(
            body: body(CreateJobRequest(platform: "pinterest", scope: "board:1", totalEstimate: 50)))
        #expect(result.statusCode == 201)
        #expect(result.response.status == "created")
        #expect(result.response.jobId == fake.createdID)
        #expect(result.response.caps == caps)
        #expect(fake.createdPlatforms == [.pinterest])
    }

    @Test("POST /jobs before consent → 403 consent_required, no job created")
    func createBlockedWithoutConsent() async throws {
        let fake = FakeJobLedger()
        let result = await routes(fake, consent: false).handleCreateJob(
            body: body(CreateJobRequest(platform: "pinterest")))
        #expect(result.statusCode == 403)
        #expect(result.response.status == "consent_required")
        #expect(fake.createdPlatforms.isEmpty) // gated before the ledger is touched
    }

    // MARK: task 8 — resume the same job

    @Test("POST /jobs with resumeJobId for a RESUMABLE job reopens it (no new job)")
    func resumeReopensResumable() async throws {
        let fake = FakeJobLedger()
        let resumeID = UUID()
        fake.seedExisting(resumeID)
        fake.currentStatus = .paused          // paused by a user Pause / wall — resumable
        let result = await routes(fake).handleCreateJob(
            body: body(CreateJobRequest(platform: "pinterest", resumeJobId: resumeID)))

        #expect(result.statusCode == 201)
        #expect(result.response.jobId == resumeID)        // SAME job, not a fresh id
        #expect(fake.createdPlatforms.isEmpty)            // no new job minted
        #expect(fake.statusUpdates.map(\.jobID) == [resumeID])   // reopened…
        #expect(fake.statusUpdates.map(\.status) == [.open])     // …to open
    }

    @Test("POST /jobs with resumeJobId for a TERMINAL job mints a fresh job")
    func resumeTerminalStartsFresh() async throws {
        let fake = FakeJobLedger()
        let resumeID = UUID()
        fake.seedExisting(resumeID)
        fake.currentStatus = .complete        // finished — a stale checkpoint must not revive it
        let result = await routes(fake).handleCreateJob(
            body: body(CreateJobRequest(platform: "pinterest", resumeJobId: resumeID)))

        #expect(result.statusCode == 201)
        #expect(result.response.jobId == fake.createdID)  // a NEW job
        #expect(fake.createdPlatforms == [.pinterest])
        #expect(fake.statusUpdates.isEmpty)               // the terminal job untouched
    }

    @Test("POST /jobs with an ABSENT resumeJobId mints a fresh job (safe stale id)")
    func resumeAbsentStartsFresh() async throws {
        let fake = FakeJobLedger()
        let result = await routes(fake).handleCreateJob(
            body: body(CreateJobRequest(platform: "pinterest", resumeJobId: UUID())))

        #expect(result.statusCode == 201)
        #expect(result.response.jobId == fake.createdID)  // fell through to a new job
        #expect(fake.createdPlatforms == [.pinterest])
        #expect(fake.statusUpdates.isEmpty)
    }

    @Test("POST /jobs unknown platform → 400")
    func createBadPlatform() async throws {
        let result = await routes(FakeJobLedger()).handleCreateJob(
            body: body(CreateJobRequest(platform: "myspace")))
        #expect(result.statusCode == 400)
        #expect(result.response.status == "error")
    }

    @Test("POST /jobs malformed JSON → 400")
    func createMalformed() async throws {
        let result = await routes(FakeJobLedger()).handleCreateJob(body: Data("{".utf8))
        #expect(result.statusCode == 400)
    }

    @Test("GET known-sources → 200 with the sorted landed set")
    func knownSourcesSorted() async throws {
        let fake = FakeJobLedger()
        _ = try await fake.createJob(platform: .pinterest, scope: nil, totalEstimate: nil)
        fake.knownSources = ["pin-C", "pin-A", "pin-B"]
        let result = await routes(fake).handleKnownSources(jobID: fake.createdID)
        #expect(result.statusCode == 200)
        #expect(result.response.status == "known_sources")
        #expect(result.response.sourceIds == ["pin-A", "pin-B", "pin-C"]) // sorted
    }

    @Test("GET known-sources for an absent job → 404")
    func knownSourcesNotFound() async throws {
        let result = await routes(FakeJobLedger()).handleKnownSources(jobID: UUID())
        #expect(result.statusCode == 404)
        #expect(result.response.status == "error")
    }

    @Test("POST complete with empty body defaults to .complete")
    func completeDefault() async throws {
        let fake = FakeJobLedger()
        _ = try await fake.createJob(platform: .twitter, scope: nil, totalEstimate: nil)
        let result = await routes(fake).handleComplete(jobID: fake.createdID, body: Data())
        #expect(result.statusCode == 200)
        #expect(result.response.status == "ok")
        #expect(fake.statusUpdates.map(\.status) == [.complete])
    }

    @Test("POST complete with an explicit status transitions accordingly")
    func completeExplicitStatus() async throws {
        let fake = FakeJobLedger()
        _ = try await fake.createJob(platform: .twitter, scope: nil, totalEstimate: nil)
        _ = await routes(fake).handleComplete(
            jobID: fake.createdID, body: body(CompleteJobRequest(status: "halted")))
        #expect(fake.statusUpdates.map(\.status) == [.halted])
    }

    @Test("POST complete with a bad status → 400, no transition")
    func completeBadStatus() async throws {
        let fake = FakeJobLedger()
        _ = try await fake.createJob(platform: .twitter, scope: nil, totalEstimate: nil)
        let result = await routes(fake).handleComplete(
            jobID: fake.createdID, body: body(CompleteJobRequest(status: "reopen")))
        #expect(result.statusCode == 400)
        #expect(fake.statusUpdates.isEmpty)
    }

    @Test("POST complete for an absent job → 404")
    func completeNotFound() async throws {
        let result = await routes(FakeJobLedger()).handleComplete(jobID: UUID(), body: Data())
        #expect(result.statusCode == 404)
    }
}

@Suite("CaptureRoutes ledger recording (real ingest, fake ledger)")
struct CaptureRoutesLedgerTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func taggedRequest(
        _ env: ServerTestEnv, image: String, sourceId: String, jobId: UUID
    ) -> Data {
        CaptureRequest(
            image: image,
            provenance: ProvenanceDTO(
                platform: "pinterest",
                originalURL: "https://pinterest.com/pin/\(sourceId)/"),
            collectionId: env.collectionID, jobId: jobId, sourceId: sourceId
        ).jsonData()
    }

    @Test("a tagged capture records an .ingested item with the blob hash")
    func tagsIngested() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let fake = FakeJobLedger()
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { env.collectionID },
            jobLedger: fake)
        let jobID = UUID()

        let result = await routes.handleIngest(
            body: taggedRequest(env, image: ServerFixtures.pngBase64(), sourceId: "pin-1", jobId: jobID),
            now: Self.now)

        #expect(result.statusCode == 200)
        #expect(fake.recorded.count == 1)
        let item = try #require(fake.recorded.first)
        #expect(item.jobID == jobID)
        #expect(item.sourceID == "pin-1")
        #expect(item.status == .ingested)
        #expect(item.blobHash != nil)
    }

    @Test("re-capturing the same bytes+provenance records a .deduped item")
    func tagsDeduped() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let fake = FakeJobLedger()
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { env.collectionID },
            jobLedger: fake)
        let jobID = UUID()
        let body = taggedRequest(env, image: ServerFixtures.pngBase64(), sourceId: "pin-1", jobId: jobID)

        _ = await routes.handleIngest(body: body, now: Self.now)
        _ = await routes.handleIngest(body: body, now: Self.now)

        #expect(fake.recorded.map(\.status) == [.ingested, .deduped])
    }

    @Test("a tagged capture that fails to ingest records a .permanentFailed item")
    func tagsPermanentFailed() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let fake = FakeJobLedger()
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { env.collectionID },
            jobLedger: fake)
        let jobID = UUID()
        let bad = CaptureRequest(
            image: ServerFixtures.nonImageBase64(),
            provenance: ProvenanceDTO(platform: "web", originalURL: "https://e.com/x"),
            collectionId: env.collectionID, jobId: jobID, sourceId: "src-9").jsonData()

        let result = await routes.handleIngest(body: bad, now: Self.now)

        #expect(result.statusCode == 422)
        #expect(fake.recorded.count == 1)
        #expect(fake.recorded.first?.status == .permanentFailed)
        #expect(fake.recorded.first?.blobHash == nil)
    }

    @Test("a tagged capture's reply carries the job status (paused → relay feedback)")
    func taggedReplyCarriesJobStatus() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let fake = FakeJobLedger()
        let jobID = UUID()
        fake.seedExisting(jobID)     // the job the capture is tagged with exists
        fake.currentStatus = .paused // the user paused mid-sweep in the app
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { env.collectionID },
            jobLedger: fake)

        let result = await routes.handleIngest(
            body: taggedRequest(env, image: ServerFixtures.pngBase64(), sourceId: "pin-1", jobId: jobID),
            now: Self.now)

        #expect(result.statusCode == 200)
        #expect(result.response.jobStatus == "paused") // the extension halts on this
    }

    @Test("an UNtagged capture's reply omits jobStatus (wire unchanged)")
    func untaggedReplyOmitsJobStatus() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { env.collectionID },
            jobLedger: FakeJobLedger())
        let result = await routes.handleIngest(
            body: CaptureRequest.sample(collectionId: env.collectionID).jsonData(), now: Self.now)
        #expect(result.response.jobStatus == nil)
    }

    @Test("an UNtagged capture records nothing in the ledger")
    func untaggedRecordsNothing() async throws {
        let env = try await makeServerTestEnv(); defer { env.cleanup() }
        let fake = FakeJobLedger()
        let routes = CaptureRoutes(
            coordinator: env.coordinator, defaultCollectionID: { env.collectionID },
            jobLedger: fake)
        // No jobId/sourceId on this request.
        let body = CaptureRequest.sample(collectionId: env.collectionID).jsonData()

        _ = await routes.handleIngest(body: body, now: Self.now)

        #expect(fake.recorded.isEmpty)
    }
}
