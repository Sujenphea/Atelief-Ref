// AtelierIngestion tests — re-hashing what landed at the destination (008 · H5d).
//
// Three claims are load-bearing here and each has its own tests: the sample is
// capped and DETERMINISTIC (a verifier whose result depends on luck cannot be
// trusted or debugged), a corrupted destination blob is CAUGHT (the whole point),
// and a finding DELETES NOTHING (the destination is what a user restores from,
// and a false positive that pruned would be worse than the corruption it thought
// it saw).

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("BackupVerifier (008 H5d)")
struct BackupVerifierTests {

    /// A backup destination: a real (VACUUM INTO) database copy and blob files
    /// whose names really are their own content hashes — the property being
    /// checked, so it has to be true at the start.
    private struct Fixture {
        let pipeline: TempPipeline
        let target: URL
        let layout: BackupLayout

        var verifier: BackupVerifier { BackupVerifier(layout: layout) }

        func cleanup() {
            pipeline.cleanup()
            try? FileManager.default.removeItem(at: target)
        }
    }

    private func makeFixture(blobs: Int = 4) async throws -> Fixture {
        let pipeline = try await makeTempPipeline()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBackupVerifierTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = BackupLayout(target: target, libraryID: "0123456789abcdef")
        try FileManager.default.createDirectory(
            at: layout.root, withIntermediateDirectories: true)
        // A self-contained database copy, made the way a real run makes one.
        try await pipeline.services.snapshot(to: layout.database)

        let fixture = Fixture(pipeline: pipeline, target: target, layout: layout)
        for index in 0 ..< blobs {
            _ = try store(fixture, bytes: "payload-\(index)")
        }
        return fixture
    }

    /// Write `bytes` at the destination under its true content hash, returning
    /// the file it landed at.
    @discardableResult
    private func store(_ fixture: Fixture, bytes: String) throws -> BlobFile {
        let data = Data(bytes.utf8)
        let hash = ContentHasher.hash(data)
        try fixture.layout.store.storeBlob(data, hash: hash, fileExtension: "png")
        return BlobFile(hash: hash, fileExtension: "png")
    }

    /// Every blob file at the destination, for the "nothing was deleted" checks.
    private func destinationFiles(_ fixture: Fixture) -> Set<String> {
        Set(fixture.layout.store.enumerateBlobFiles().map(\.hash))
    }

    // MARK: - Sample selection

    /// A stand-in tree — the selection is pure path-free math over names.
    private func files(_ count: Int) -> [BlobFile] {
        (0 ..< count).map { BlobFile(hash: String(format: "%08x", $0), fileExtension: "png") }
    }

    @Test("the sample is capped at the limit")
    func sampleIsCapped() {
        let picked = BackupVerifier.sample(files(1_000), limit: 10, seed: 0)
        // The cap is the entire reason a check on an iCloud destination is
        // affordable: 10 downloads, not 1,000.
        #expect(picked.count == 10)
    }

    @Test("the same tree, limit and seed pick exactly the same files")
    func sampleIsDeterministic() {
        let tree = files(1_000)
        let first = BackupVerifier.sample(tree, limit: 16, seed: 7)
        let second = BackupVerifier.sample(tree.shuffled(), limit: 16, seed: 7)
        // Shuffled input, identical output: the selection sorts first, so it
        // cannot depend on the order the filesystem happened to enumerate in.
        #expect(first == second)
    }

    @Test("a different seed rotates the sample, still capped")
    func sampleRotatesWithSeed() {
        let tree = files(1_000)
        let first = BackupVerifier.sample(tree, limit: 10, seed: 0)
        let second = BackupVerifier.sample(tree, limit: 10, seed: 3)
        // Successive checks must drift across the tree, or a capped check would
        // re-read the same ten files forever and never see the damage.
        #expect(first != second)
        #expect(second.count == 10)
    }

    @Test("the sample spreads across the tree instead of taking the front")
    func sampleSpreads() {
        let tree = files(1_000)
        let picked = BackupVerifier.sample(tree, limit: 10, seed: 0)
        // Every hundredth file, end to end. Taking the first ten would verify
        // one shard directory and imply the whole backup.
        #expect(picked.map(\.hash) == stride(from: 0, to: 1_000, by: 100).map { tree[$0].hash })
    }

    /// The case a stride-relative offset could not rotate at all: with a tree
    /// only a little larger than the limit the stride collapses to 1, `seed %
    /// stride` is 0 for every seed, and the check re-read the same files forever
    /// — on exactly the small destinations where rotating is cheapest.
    @Test("a nearly-full sample still rotates when the stride collapses to 1")
    func sampleRotatesWhenStrideIsOne() {
        let tree = files(15)
        let first = BackupVerifier.sample(tree, limit: 10, seed: 0)
        let second = BackupVerifier.sample(tree, limit: 10, seed: 4)

        #expect(first.count == 10)
        #expect(second.count == 10)
        #expect(first != second)
        // Still a SET of distinct files, not one wrapped onto another: the walk
        // spans less than a lap, so no two picks can land on the same index.
        #expect(Set(second.map(\.hash)).count == 10)
    }

    @Test("a tree at or under the limit is returned whole")
    func smallTreeIsSampledEntirely() {
        let picked = BackupVerifier.sample(files(5), limit: 10, seed: 4)
        #expect(picked.count == 5)
        #expect(picked.map(\.hash) == files(5).map(\.hash))
    }

    @Test("a zero limit picks nothing rather than trapping")
    func zeroLimitPicksNothing() {
        #expect(BackupVerifier.sample(files(10), limit: 0, seed: 0).isEmpty)
    }

    // MARK: - A good destination

    @Test("an intact backup verifies clean")
    func intactBackupIsClean() async throws {
        let fixture = try await makeFixture(blobs: 4)
        defer { fixture.cleanup() }

        let result = try await fixture.verifier.verify(scope: .full)

        #expect(result.isClean)
        #expect(result.databaseHealthy)
        #expect(result.checked == 4)
        #expect(result.totalFiles == 4)
        #expect(result.bytesRead > 0)
        #expect(result.wasExhaustive)
    }

    @Test("a sampled check reports what it looked at AND what it looked at it of")
    func sampledCheckReportsBothCounts() async throws {
        let fixture = try await makeFixture(blobs: 10)
        defer { fixture.cleanup() }

        let result = try await fixture.verifier.verify(scope: .sample(limit: 3, seed: 0))

        // "3 checked" without "of 10" would read as a claim about the backup.
        #expect(result.checked == 3)
        #expect(result.totalFiles == 10)
        #expect(result.isClean)
        #expect(!result.wasExhaustive)
    }

    @Test("progress is reported over the SAMPLE, not the whole destination")
    func progressCoversTheSample() async throws {
        let fixture = try await makeFixture(blobs: 10)
        defer { fixture.cleanup() }

        let totals = TotalsRecorder()
        _ = try await fixture.verifier.verify(
            scope: .sample(limit: 3, seed: 0),
            onProgress: { _, total in totals.record(total) })

        // A bar that filled to 3/10 and stopped would look like a failure.
        #expect(totals.distinct == [3])
    }

    // MARK: - A damaged destination

    @Test("a flipped byte is caught, and the file is left exactly where it was")
    func corruptedBlobFailsAndIsKept() async throws {
        let fixture = try await makeFixture(blobs: 4)
        defer { fixture.cleanup() }
        let victim = try store(fixture, bytes: "the-one-that-rots")
        let url = fixture.layout.store.blobURL(
            hash: victim.hash, fileExtension: victim.fileExtension)
        // Flip a byte, KEEP the name — the exact shape of silent bit rot, and
        // the only reason re-hashing beats comparing sizes or dates.
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0xFF
        try bytes.write(to: url)
        let before = destinationFiles(fixture)

        let result = try await fixture.verifier.verify(scope: .full)

        #expect(!result.isClean)
        #expect(result.mismatched == [victim.hash])
        #expect(result.unreadable.isEmpty)
        // A finding is a report, never a repair. The destination is what the
        // user restores from; deleting on suspicion would turn one bad file into
        // a missing one.
        #expect(destinationFiles(fixture) == before)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an unreadable file is reported apart from a mismatch")
    func unreadableIsNotCorruption() async throws {
        let fixture = try await makeFixture(blobs: 2)
        defer { fixture.cleanup() }
        let victim = try store(fixture, bytes: "vanishes")
        let url = fixture.layout.store.blobURL(
            hash: victim.hash, fileExtension: victim.fileExtension)
        // Enumerable but unopenable — the stand-in for a dataless iCloud file
        // whose download failed. (A deleted file wouldn't do: it never reaches
        // the sample, because enumeration wouldn't list it.)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        let result = try await fixture.verifier.verify(scope: .full)

        #expect(result.unreadable == [victim.hash])
        // Never claimed as corruption: the bytes were never seen, so saying they
        // are wrong would be a guess dressed as a measurement.
        #expect(result.mismatched.isEmpty)
        #expect(!result.isClean)
    }

    @Test("one bad file does not stop the pass")
    func oneBadFileDoesNotAbortThePass() async throws {
        let fixture = try await makeFixture(blobs: 5)
        defer { fixture.cleanup() }
        let victim = try store(fixture, bytes: "rotten")
        let url = fixture.layout.store.blobURL(
            hash: victim.hash, fileExtension: victim.fileExtension)
        try Data("not the right bytes".utf8).write(to: url)

        let result = try await fixture.verifier.verify(scope: .full)

        // Stopping at the first finding would hide whether this is one bad file
        // or a dying drive — the only thing that tells a user what to do.
        #expect(result.checked == 6)
        #expect(result.mismatched.count == 1)
    }

    @Test("a corrupt database copy fails the check without touching the blobs")
    func corruptDatabaseFails() async throws {
        let fixture = try await makeFixture(blobs: 3)
        defer { fixture.cleanup() }
        try Data("this is not a database".utf8).write(to: fixture.layout.database)
        let before = destinationFiles(fixture)

        let result = try await fixture.verifier.verify(scope: .full)

        #expect(!result.databaseHealthy)
        #expect(!result.isClean)
        // The blobs are fine and were checked anyway — a bad database copy is
        // replaced by the next run, and the media is what can't be recreated.
        #expect(result.mismatched.isEmpty)
        #expect(destinationFiles(fixture) == before)
    }

    @Test("no database at the destination is 'nothing to check', not 'damaged'")
    func missingDatabaseThrows() async throws {
        let fixture = try await makeFixture(blobs: 1)
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.layout.database)

        await #expect(throws: BackupVerifier.VerifyError.noBackupFound) {
            try await fixture.verifier.verify(scope: .full)
        }
    }

    // MARK: - Cancellation

    @Test("a cancelled check reports cancelled, verifies nothing, and deletes nothing")
    func cancelledCheckIsCancelled() async throws {
        let fixture = try await makeFixture(blobs: 6)
        defer { fixture.cleanup() }
        let before = destinationFiles(fixture)

        let result = try await fixture.verifier.verify(
            scope: .full, isCancelled: { true })

        #expect(result.cancelled)
        // A cancelled pass is never clean: it did not finish looking, and
        // "verified" is a claim rather than an impression.
        #expect(!result.isClean)
        #expect(result.checked == 0)
        #expect(destinationFiles(fixture) == before)
    }

    @Test("a cancel that arrives after every file still reports what it found")
    func lateCancelStillReports() async throws {
        let fixture = try await makeFixture(blobs: 3)
        defer { fixture.cleanup() }

        let done = Latch()
        let result = try await fixture.verifier.verify(
            scope: .full,
            isCancelled: { done.isSet },
            onProgress: { completed, total in
                if completed == total { done.set() }
            })

        // Cancellation is judged by what it COST. Nothing was skipped, so this
        // pass really did check everything it was asked to.
        #expect(!result.cancelled)
        #expect(result.checked == 3)
    }
}

// MARK: - Test doubles

/// Records the `total` a check reports with each progress tick.
private final class TotalsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [Int] = []

    func record(_ total: Int) {
        lock.lock(); defer { lock.unlock() }
        totals.append(total)
    }

    var distinct: Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set(totals)
    }
}

/// A one-way thread-safe flag, for cancelling at a chosen moment.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
