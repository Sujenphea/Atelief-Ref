// AtelierIngestion tests — copying blobs to an off-device destination (008 · H5).
//
// Two things carry the feature and are tested hardest:
//   • the DIFF, because it decides what an incremental run does and doesn't do;
//   • the STAGING, because "the destination already has it" is only a safe
//     shortcut if a file that exists is a file that is complete (A2).

import AtelierCore
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("MediaBackupper (008 H5)")
struct MediaBackupperTests {

    /// A source store, a destination store, and the temp root holding both.
    private struct Pair {
        let source: MediaStore
        let destination: MediaStore
        let root: URL
        var backupper: MediaBackupper {
            MediaBackupper(source: source, destination: destination)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makePair() throws -> Pair {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierBackupperTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Pair(
            source: MediaStore(root: root.appendingPathComponent("live", isDirectory: true)),
            destination: MediaStore(root: root.appendingPathComponent("backup", isDirectory: true)),
            root: root)
    }

    /// PNG, so `ImageMetadata.fileExtension(forMIMEType:)` yields "png" and the
    /// tests exercise the same extension derivation production does.
    private func ref(_ hash: String) -> BlobRef {
        BlobRef(blobHash: hash, mimeType: "image/png")
    }

    /// Put `bytes` at the store's content-addressed path for `hash`.
    @discardableResult
    private func put(_ bytes: String, hash: String, in store: MediaStore) throws -> URL {
        try store.storeBlob(Data(bytes.utf8), hash: hash, fileExtension: "png")
    }

    // MARK: - The diff

    @Test("an empty destination is missing everything")
    func diffEmptyDestination() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.source)
        try put("b", hash: "bbbb2222", in: pair.source)

        let missing = pair.backupper.missing(from: [ref("aaaa1111"), ref("bbbb2222")])
        #expect(missing.map(\.blobHash) == ["aaaa1111", "bbbb2222"])
    }

    @Test("a partially-filled destination is missing only the rest")
    func diffPartialDestination() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.destination)

        let missing = pair.backupper.missing(
            from: [ref("aaaa1111"), ref("bbbb2222"), ref("cccc3333")])
        #expect(missing.map(\.blobHash) == ["bbbb2222", "cccc3333"])
    }

    @Test("an up-to-date destination has nothing missing — the no-op re-run")
    func diffIdenticalDestination() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.destination)
        try put("b", hash: "bbbb2222", in: pair.destination)

        #expect(pair.backupper.missing(from: [ref("aaaa1111"), ref("bbbb2222")]).isEmpty)
    }

    @Test("extra blobs at the destination are IGNORED, never reported or removed")
    func diffIgnoresExtras() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("gone", hash: "dddd4444", in: pair.destination)

        // A blob the live library deleted still sits in the backup. That is the
        // point of a backup — pruning it here would make "delete" propagate
        // off-device, which is exactly what a user restores FROM.
        #expect(pair.backupper.missing(from: [ref("aaaa1111")]).map(\.blobHash) == ["aaaa1111"])
        #expect(pair.destination.hasBlob(hash: "dddd4444", fileExtension: "png"))
    }

    @Test("the diff is keyed by hash, so duplicates collapse to one copy")
    func diffDeduplicates() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let missing = pair.backupper.missing(
            from: [ref("aaaa1111"), ref("aaaa1111"), ref("bbbb2222")])
        #expect(missing.map(\.blobHash) == ["aaaa1111", "bbbb2222"])
    }

    @Test("the extension comes from the mime type, matching how the file was stored")
    func diffUsesMimeDerivedExtension() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        // Stored as ".jpeg" — NOT ".jpg" — because that is what
        // `UTType(mimeType:).preferredFilenameExtension` gives, and the live
        // store wrote it that way. A diff assuming "jpg" would re-copy forever.
        try pair.destination.storeBlob(
            Data("j".utf8), hash: "eeee5555", fileExtension: "jpeg")

        let jpeg = BlobRef(blobHash: "eeee5555", mimeType: "image/jpeg")
        #expect(pair.backupper.missing(from: [jpeg]).isEmpty)
    }

    @Test("an unresolvable mime yields the dotless path the store actually wrote")
    func diffHandlesEmptyExtension() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try pair.destination.storeBlob(
            Data("x".utf8), hash: "ffff6666", fileExtension: "")

        let unknown = BlobRef(blobHash: "ffff6666", mimeType: "application/x-nonsense")
        #expect(pair.backupper.missing(from: [unknown]).isEmpty)
    }

    @Test("an empty referenced set is an empty diff")
    func diffEmptyInput() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        #expect(pair.backupper.missing(from: []).isEmpty)
    }

    // MARK: - The reverse diff (008 · H5c)

    /// The restore direction reads the FILE TREE, not the database — same four
    /// cases as the diff above, driven from the other end.
    @Test("an empty destination is missing every file the source holds")
    func fileDiffEmptyDestination() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.source)
        try put("b", hash: "bbbb2222", in: pair.source)

        #expect(pair.backupper.missingFiles() == [
            BlobFile(hash: "aaaa1111", fileExtension: "png"),
            BlobFile(hash: "bbbb2222", fileExtension: "png"),
        ])
    }

    @Test("a partially-filled destination is missing only the rest")
    func fileDiffPartialDestination() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.source)
        try put("b", hash: "bbbb2222", in: pair.source)
        try put("a", hash: "aaaa1111", in: pair.destination)

        #expect(pair.backupper.missingFiles().map(\.hash) == ["bbbb2222"])
    }

    @Test("an up-to-date destination has nothing missing")
    func fileDiffIdenticalDestination() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        for hash in ["aaaa1111", "bbbb2222"] {
            try put(hash, hash: hash, in: pair.source)
            try put(hash, hash: hash, in: pair.destination)
        }

        #expect(pair.backupper.missingFiles().isEmpty)
    }

    @Test("extra blobs at the destination are ignored, never reported or removed")
    func fileDiffIgnoresExtras() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.source)
        // A blob the live library has that the backup never saw. Restore must
        // not touch it — reintroducing pruning in THIS direction would delete
        // media captured since the backup was taken.
        try put("newer", hash: "dddd4444", in: pair.destination)

        #expect(pair.backupper.missingFiles().map(\.hash) == ["aaaa1111"])
        #expect(pair.destination.hasBlob(hash: "dddd4444", fileExtension: "png"))
    }

    @Test("an empty source tree is an empty diff")
    func fileDiffEmptySource() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        #expect(pair.backupper.missingFiles().isEmpty)
    }

    @Test("the extension comes from the FILENAME, so no mime guess can drift")
    func fileDiffUsesStoredExtension() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        // ".jpeg" is what the store wrote; a diff that re-derived "jpg" from a
        // mime type would report this as missing forever.
        try pair.source.storeBlob(Data("j".utf8), hash: "eeee5555", fileExtension: "jpeg")
        try pair.source.storeBlob(Data("x".utf8), hash: "ffff6666", fileExtension: "")

        #expect(pair.backupper.missingFiles() == [
            BlobFile(hash: "eeee5555", fileExtension: "jpeg"),
            BlobFile(hash: "ffff6666", fileExtension: ""),
        ])
    }

    @Test("copying the reverse diff lands every file, byte for byte")
    func copyFilesLandsBytes() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("hello restore", hash: "aaaa1111", in: pair.source)
        try pair.source.storeBlob(Data("dotless".utf8), hash: "ffff6666", fileExtension: "")

        let result = await pair.backupper.copyFiles(pair.backupper.missingFiles())
        #expect(result.copied == 2)
        #expect(result.isComplete)
        #expect(String(decoding: try pair.destination.readBlob(
            hash: "aaaa1111", fileExtension: "png"), as: UTF8.self) == "hello restore")
        #expect(String(decoding: try pair.destination.readBlob(
            hash: "ffff6666", fileExtension: ""), as: UTF8.self) == "dotless")
        #expect(pair.backupper.missingFiles().isEmpty)
    }

    // MARK: - Copying

    @Test("copied blobs land at the same sharded path, byte for byte")
    func copiesBytesToShardedPath() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("hello backup", hash: "aaaa1111", in: pair.source)

        let result = await pair.backupper.copy([ref("aaaa1111")])
        #expect(result.copied == 1)
        #expect(result.bytesCopied == Int64("hello backup".utf8.count))
        #expect(result.isComplete)

        let bytes = try pair.destination.readBlob(hash: "aaaa1111", fileExtension: "png")
        #expect(String(decoding: bytes, as: UTF8.self) == "hello backup")
        // Same shard scheme on both sides — the diff depends on it.
        let components = pair.destination
            .blobURL(hash: "aaaa1111", fileExtension: "png").pathComponents
        #expect(Array(components.suffix(4)) == ["blobs", "aa", "aa", "aaaa1111.png"])
    }

    @Test("copying leaves NO staging leftovers at the destination")
    func stagingIsCleanedUp() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        for hash in ["aaaa1111", "bbbb2222", "cccc3333"] {
            try put(hash, hash: hash, in: pair.source)
        }

        _ = await pair.backupper.copy([ref("aaaa1111"), ref("bbbb2222"), ref("cccc3333")])

        let cache = pair.destination.layout.cache
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("a referenced blob with no file at the source is reported, not fatal")
    func missingSourceFileIsReported() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("here", hash: "aaaa1111", in: pair.source)

        // "bbbb2222" is referenced by a row but its bytes are gone.
        let result = await pair.backupper.copy([ref("aaaa1111"), ref("bbbb2222")])
        #expect(result.copied == 1)
        #expect(result.missingAtSource == ["bbbb2222"])
        #expect(!result.isComplete)
        // The one that COULD be copied still was — one bad file must not cost
        // the user the rest of the batch.
        #expect(pair.destination.hasBlob(hash: "aaaa1111", fileExtension: "png"))
    }

    @Test("a blob already at the destination is not re-copied")
    func alreadyPresentIsNotRecopied() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("live bytes", hash: "aaaa1111", in: pair.source)
        try put("backed up", hash: "aaaa1111", in: pair.destination)

        let result = await pair.backupper.copy([ref("aaaa1111")])
        #expect(result.alreadyPresent == 1)
        #expect(result.copied == 0)
        #expect(result.bytesCopied == 0)
        // Content-addressing says the bytes are equivalent, so the existing file
        // is left alone rather than rewritten.
        let bytes = try pair.destination.readBlob(hash: "aaaa1111", fileExtension: "png")
        #expect(String(decoding: bytes, as: UTF8.self) == "backed up")
    }

    @Test("a copy that cannot be written is reported and the batch continues")
    func copyFailureIsReported() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        try put("a", hash: "aaaa1111", in: pair.source)
        try put("b", hash: "bbbb2222", in: pair.source)

        // A FILE where the "aa/aa" shard directory needs to be: creating the
        // directory fails, so this one blob cannot land. (Standing in for the
        // realistic causes — a full disk, a revoked grant.)
        let blobs = pair.destination.layout.blobs
        try FileManager.default.createDirectory(
            at: blobs.appendingPathComponent("aa"), withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: blobs.appendingPathComponent("aa/aa"))

        let result = await pair.backupper.copy([ref("aaaa1111"), ref("bbbb2222")])
        #expect(result.failed == ["aaaa1111"])
        #expect(result.copied == 1)
        #expect(!result.isComplete)
        #expect(pair.destination.hasBlob(hash: "bbbb2222", fileExtension: "png"))
    }

    @Test("an interrupted copy leaves nothing to be mistaken for a finished one")
    func interruptedCopyResumes() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        for hash in ["aaaa1111", "bbbb2222"] {
            try put("payload-\(hash)", hash: hash, in: pair.source)
        }

        // Cancelled before anything ran.
        let stopped = await pair.backupper.copy(
            [ref("aaaa1111"), ref("bbbb2222")], maxConcurrent: 1, isCancelled: { true })
        #expect(stopped.cancelled)
        #expect(stopped.copied == 0)
        // The invariant: no half-file at a content-addressed path, so the next
        // run's "already there" check cannot be fooled.
        #expect(!pair.destination.hasBlob(hash: "aaaa1111", fileExtension: "png"))
        #expect(!pair.destination.hasBlob(hash: "bbbb2222", fileExtension: "png"))

        // Re-running with the flag clear completes the work.
        let resumed = await pair.backupper.copy(
            pair.backupper.missing(from: [ref("aaaa1111"), ref("bbbb2222")]))
        #expect(resumed.copied == 2)
        #expect(resumed.isComplete)
        let landed = try pair.destination.readBlob(hash: "bbbb2222", fileExtension: "png")
        #expect(String(decoding: landed, as: UTF8.self) == "payload-bbbb2222")
    }

    @Test("cancelling mid-run keeps what already landed and skips the rest")
    func cancelMidRunIsResumable() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let hashes = (0 ..< 12).map { String(format: "%08x", $0 * 0x0101_0101) }
        for hash in hashes { try put(hash, hash: hash, in: pair.source) }

        // Trip the flag once the first few files are through.
        let counter = Counter()
        let result = await pair.backupper.copy(
            hashes.map(ref), maxConcurrent: 1,
            isCancelled: { counter.bump() > 3 })

        #expect(result.cancelled)
        #expect(result.skipped > 0)
        #expect(result.copied + result.skipped == hashes.count)
        // Whatever landed is complete, so the follow-up run only does the rest.
        let remaining = pair.backupper.missing(from: hashes.map(ref))
        #expect(remaining.count == hashes.count - result.copied)
        let finish = await pair.backupper.copy(remaining)
        #expect(finish.isComplete)
        #expect(pair.backupper.missing(from: hashes.map(ref)).isEmpty)
    }

    @Test("progress is reported monotonically, once per file, up to the total")
    func progressIsMonotonic() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let hashes = (0 ..< 8).map { String(format: "%08x", 0x1000_0000 + $0) }
        for hash in hashes { try put(hash, hash: hash, in: pair.source) }

        let recorder = ProgressRecorder()
        let result = await pair.backupper.copy(
            hashes.map(ref), maxConcurrent: 4,
            onProgress: { completed, total in recorder.record(completed, total) })

        #expect(result.copied == hashes.count)
        #expect(recorder.completions == Array(1 ... hashes.count))
        #expect(recorder.totals.allSatisfy { $0 == hashes.count })
    }

    @Test("copying nothing is a no-op, not an error")
    func emptyCopyIsNoop() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let result = await pair.backupper.copy([])
        #expect(result == BackupCopyResult())
        #expect(result.isComplete)
    }
}

// MARK: - Test doubles

/// A thread-safe call counter, for tripping cancellation after N reads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Records the `(completed, total)` pairs a copy reports, in order.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs: [(Int, Int)] = []

    func record(_ completed: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        pairs.append((completed, total))
    }

    var completions: [Int] {
        lock.lock(); defer { lock.unlock() }
        return pairs.map(\.0)
    }

    var totals: [Int] {
        lock.lock(); defer { lock.unlock() }
        return pairs.map(\.1)
    }
}
