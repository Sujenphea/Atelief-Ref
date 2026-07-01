// AtelierIngestion — content hasher tests (chunk 3, decision C5)
//
// Known-answer SHA-256 vectors, streamed-vs-in-memory equivalence, and the
// lowercased-hex / 64-char format guarantees.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("ContentHasher")
struct ContentHasherTests {
    // MARK: - Known-answer vectors

    @Test("SHA-256 of empty data matches the standard test vector")
    func emptyKnownAnswer() {
        #expect(ContentHasher.hash(Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("SHA-256 of \"abc\" matches the standard test vector")
    func abcKnownAnswer() {
        #expect(ContentHasher.hash(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Format guarantees

    @Test("hash is exactly 64 lowercased hex characters")
    func hexFormat() {
        let hash = ContentHasher.hash(Data("some arbitrary bytes 12345".utf8))
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(hash == hash.lowercased())
    }

    // MARK: - Streamed == in-memory

    @Test("streamed hash(contentsOf:) equals in-memory hash(_:) for the same bytes")
    func streamedEqualsInMemory() throws {
        // Larger than the 1 MiB stream chunk so multiple read/update cycles run.
        var bytes = Data(count: 0)
        for i in 0 ..< (3 * (1 << 20) + 777) {
            bytes.append(UInt8(i & 0xff))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try ContentHasher.hash(contentsOf: url)
        let inMemory = ContentHasher.hash(bytes)
        #expect(streamed == inMemory)
    }

    @Test("streamed hash of an empty file matches the empty-data vector")
    func streamedEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ContentHasher.hash(contentsOf: url)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
