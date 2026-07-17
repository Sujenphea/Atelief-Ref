//
//  SweepFailuresTests.swift
//  AtelierRefsTests
//
//  034 P2 — the bulk-sweep "Failed N" surface. `sweepFailures` is the read the
//  expandable failure list + Retry use: it returns ONLY the failed job items
//  (retryable + permanent), newest-change first. The retry itself re-opens the
//  job (exercised via the shared status path); here we pin the failure filter.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Bulk sweep failures (034 P2)")
struct SweepFailuresTests {

    private func makeModel() async throws -> (IngestionModel, AppServices) {
        let dbPath = NSTemporaryDirectory() + "sweep-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        return (model, services)
    }

    @Test("sweepFailures returns only failed items (retryable + permanent), not the rest")
    func onlyFailures() async throws {
        let (model, services) = try await makeModel()
        let job = try await services.createJob(platform: .twitter)
        try await services.recordJobItem(jobID: job.id, sourceID: "ok1", status: .ingested, blobHash: "h1")
        try await services.recordJobItem(jobID: job.id, sourceID: "dup1", status: .deduped, blobHash: "h2")
        try await services.recordJobItem(jobID: job.id, sourceID: "skip1", status: .skipped)
        try await services.recordJobItem(jobID: job.id, sourceID: "temp1", status: .retryableFailed)
        try await services.recordJobItem(jobID: job.id, sourceID: "perm1", status: .permanentFailed)

        let failures = await model.sweepFailures(jobID: job.id)
        #expect(failures.count == 2)
        #expect(Set(failures.map(\.sourceID)) == ["temp1", "perm1"])
        #expect(failures.allSatisfy { $0.status == .retryableFailed || $0.status == .permanentFailed })
    }

    @Test("sweepFailures is empty for a clean sweep")
    func noFailures() async throws {
        let (model, services) = try await makeModel()
        let job = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(jobID: job.id, sourceID: "p1", status: .ingested, blobHash: "h1")

        let failures = await model.sweepFailures(jobID: job.id)
        #expect(failures.isEmpty)
    }
}
