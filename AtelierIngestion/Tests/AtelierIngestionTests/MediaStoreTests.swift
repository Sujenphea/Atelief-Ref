// AtelierIngestion — MediaStore store tests (chunk 2, decision T10)
//
// Covers the content-addressed blob + thumbnail store: deterministic sharded
// paths, byte round-trips, idempotent writes, shard-dir creation, no partial /
// stray temp files, the concurrent same-bytes race, existence checks, and
// missing reads.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("MediaStore")
struct MediaStoreTests {
    // A known lowercased-hex hash (SHA-256 length, 64 chars). Sharded as ab/cd.
    static let hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    static let otherHash = "0011223344556677889900112233445566778899001122334455667788990011"

    // MARK: - Deterministic path

    @Test("blobURL shards ab/cd from the hash and appends the extension")
    func blobPathDeterministic() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let url = lib.store.blobURL(hash: Self.hash, fileExtension: "jpg")
        let expected = lib.layout.blobs
            .appendingPathComponent("ab", isDirectory: true)
            .appendingPathComponent("cd", isDirectory: true)
            .appendingPathComponent("\(Self.hash).jpg")
        #expect(url == expected)
    }

    @Test("blobURL with empty extension has no dot suffix")
    func blobPathNoExtension() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let url = lib.store.blobURL(hash: Self.hash, fileExtension: "")
        #expect(url.lastPathComponent == Self.hash)
        #expect(url.pathExtension == "")
    }

    @Test("thumbnailURL shards ab/cd and encodes the size tier")
    func thumbnailPathDeterministic() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let url = lib.store.thumbnailURL(hash: Self.hash, size: 512, fileExtension: "jpg")
        let expected = lib.layout.thumbnails
            .appendingPathComponent("ab", isDirectory: true)
            .appendingPathComponent("cd", isDirectory: true)
            .appendingPathComponent("\(Self.hash)@512.jpg")
        #expect(url == expected)
    }

    @Test("different thumbnail sizes produce different paths")
    func thumbnailSizesDiffer() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let a = lib.store.thumbnailURL(hash: Self.hash, size: 128, fileExtension: "jpg")
        let b = lib.store.thumbnailURL(hash: Self.hash, size: 512, fileExtension: "jpg")
        #expect(a != b)
    }

    @Test("shardComponents splits the first two hex pairs")
    func shardComponentsSplit() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let (first, second) = try lib.store.shardComponents(for: Self.hash)
        #expect(first == "ab")
        #expect(second == "cd")
    }

    @Test("shardComponents rejects a hash shorter than 4 chars")
    func shardComponentsGuard() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        #expect(throws: MediaStore.StoreError.self) {
            try lib.store.shardComponents(for: "ab")
        }
    }

    @Test("storeBlob throws for a hash too short to shard")
    func storeBlobRejectsShortHash() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        #expect(throws: MediaStore.StoreError.self) {
            try lib.store.storeBlob(Data([0x01]), hash: "ab", fileExtension: "bin")
        }
    }

    // MARK: - Round-trip

    @Test("storeBlob then readBlob returns identical bytes")
    func blobRoundTrip() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let data = Data("hello blob".utf8)
        let url = try lib.store.storeBlob(data, hash: Self.hash, fileExtension: "bin")
        #expect(url == lib.store.blobURL(hash: Self.hash, fileExtension: "bin"))
        let read = try lib.store.readBlob(hash: Self.hash, fileExtension: "bin")
        #expect(read == data)
    }

    @Test("storeThumbnail then readThumbnail returns identical bytes")
    func thumbnailRoundTrip() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let data = Data("hello thumb".utf8)
        let url = try lib.store.storeThumbnail(data, hash: Self.hash, size: 256, fileExtension: "jpg")
        #expect(url == lib.store.thumbnailURL(hash: Self.hash, size: 256, fileExtension: "jpg"))
        let read = try lib.store.readThumbnail(hash: Self.hash, size: 256, fileExtension: "jpg")
        #expect(read == data)
    }

    // MARK: - Idempotent write

    @Test("storing the same hash/bytes twice is a no-op returning the same URL")
    func idempotentWrite() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let data = Data("idempotent".utf8)
        let first = try lib.store.storeBlob(data, hash: Self.hash, fileExtension: "bin")
        let second = try lib.store.storeBlob(data, hash: Self.hash, fileExtension: "bin")
        #expect(first == second)

        // Exactly one file at the sharded path, content unchanged.
        #expect(try lib.store.readBlob(hash: Self.hash, fileExtension: "bin") == data)
        let shardDir = lib.layout.blobs
            .appendingPathComponent("ab", isDirectory: true)
            .appendingPathComponent("cd", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: shardDir.path)
        #expect(contents == ["\(Self.hash).bin"])
    }

    @Test("a second store under the same hash leaves the FIRST content in place")
    func idempotentSkipKeepsFirstContent() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let first = Data("first bytes".utf8)
        let second = Data("different bytes entirely".utf8)
        try lib.store.storeBlob(first, hash: Self.hash, fileExtension: "bin")
        // Content-addressing means this never happens for real, but the store
        // must idempotently skip and preserve the first content.
        try lib.store.storeBlob(second, hash: Self.hash, fileExtension: "bin")
        #expect(try lib.store.readBlob(hash: Self.hash, fileExtension: "bin") == first)
    }

    // MARK: - Shard dirs created

    @Test("the ab/cd shard directories exist after a store")
    func shardDirsCreated() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        try lib.store.storeBlob(Data("x".utf8), hash: Self.hash, fileExtension: "bin")
        var isDir: ObjCBool = false
        let shardDir = lib.layout.blobs
            .appendingPathComponent("ab", isDirectory: true)
            .appendingPathComponent("cd", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: shardDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    // MARK: - No partial / no stray temp

    @Test("after a normal store the destination is complete and cache has no leftovers")
    func noStrayTempFiles() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let data = Data("complete bytes".utf8)
        let url = try lib.store.storeBlob(data, hash: Self.hash, fileExtension: "bin")

        // Destination exists and holds the complete bytes.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == data)

        // No temp file left at the destination path itself.
        #expect(url.lastPathComponent == "\(Self.hash).bin")

        // The cache staging area holds no leftover temp files.
        let cacheContents = (try? FileManager.default.contentsOfDirectory(atPath: lib.layout.cache.path)) ?? []
        #expect(cacheContents.isEmpty)
    }

    // MARK: - Concurrent same-bytes race

    @Test("N concurrent stores of identical bytes yield exactly one file, none throw")
    func concurrentSameBytes() async throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        let data = Data("concurrent bytes".utf8)
        let store = lib.store
        let hash = Self.hash

        try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try store.storeBlob(data, hash: hash, fileExtension: "bin")
                }
            }
            // None of the calls throw; all return the same destination URL.
            let expected = store.blobURL(hash: hash, fileExtension: "bin")
            for try await url in group {
                #expect(url == expected)
            }
        }

        // Exactly one final file, with the correct content.
        let shardDir = lib.layout.blobs
            .appendingPathComponent("ab", isDirectory: true)
            .appendingPathComponent("cd", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: shardDir.path)
        #expect(contents == ["\(hash).bin"])
        #expect(try store.readBlob(hash: hash, fileExtension: "bin") == data)

        // No temp files leaked into cache under contention.
        let cacheContents = (try? FileManager.default.contentsOfDirectory(atPath: lib.layout.cache.path)) ?? []
        #expect(cacheContents.isEmpty)
    }

    // MARK: - Existence checks

    @Test("hasBlob is false before and true after a store")
    func hasBlobTransition() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        #expect(lib.store.hasBlob(hash: Self.hash, fileExtension: "bin") == false)
        try lib.store.storeBlob(Data("y".utf8), hash: Self.hash, fileExtension: "bin")
        #expect(lib.store.hasBlob(hash: Self.hash, fileExtension: "bin") == true)
        // A different hash is still absent.
        #expect(lib.store.hasBlob(hash: Self.otherHash, fileExtension: "bin") == false)
    }

    @Test("hasThumbnail distinguishes size and hash")
    func hasThumbnailTransition() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        #expect(lib.store.hasThumbnail(hash: Self.hash, size: 128, fileExtension: "jpg") == false)
        try lib.store.storeThumbnail(Data("t".utf8), hash: Self.hash, size: 128, fileExtension: "jpg")
        #expect(lib.store.hasThumbnail(hash: Self.hash, size: 128, fileExtension: "jpg") == true)
        // Different size / hash are absent.
        #expect(lib.store.hasThumbnail(hash: Self.hash, size: 512, fileExtension: "jpg") == false)
        #expect(lib.store.hasThumbnail(hash: Self.otherHash, size: 128, fileExtension: "jpg") == false)
    }

    // MARK: - Missing read

    @Test("readBlob for an absent hash throws")
    func readMissingBlobThrows() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        #expect(throws: (any Error).self) {
            try lib.store.readBlob(hash: Self.hash, fileExtension: "bin")
        }
    }

    @Test("readThumbnail for an absent tier throws")
    func readMissingThumbnailThrows() throws {
        let lib = try makeTempLibrary()
        defer { lib.cleanup() }

        #expect(throws: (any Error).self) {
            try lib.store.readThumbnail(hash: Self.hash, size: 999, fileExtension: "jpg")
        }
    }
}
