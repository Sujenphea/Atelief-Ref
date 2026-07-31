// AtelierIngestion tests — the backup manifest contract (008 · H5).
//
// The manifest is a FILE FORMAT: a future build, and possibly a future person
// with a text editor, has to read it. So the wire shape is pinned against a
// golden string. When that test fails, the correct response is almost never to
// update the expectation — it is to bump `manifest_version`.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("BackupManifest (008 H5)")
struct BackupManifestTests {

    /// A fixed manifest — no `Date()`, no UUIDs, so the encoding is byte-stable.
    private func sample() -> BackupManifest {
        BackupManifest(
            schemaVersion: "v15",
            appVersion: "1.2.3",
            libraryID: "0123456789abcdef",
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            blobCount: 42,
            blobBytes: 987_654_321,
            databaseBytes: 65_536)
    }

    // MARK: - The contract

    @Test("the on-disk shape is exactly this — bump manifest_version to change it")
    func goldenEncoding() throws {
        let data = try BackupManifest.makeEncoder().encode(sample())
        let json = String(decoding: data, as: UTF8.self)

        #expect(json == """
        {
          "app_version" : "1.2.3",
          "blob_bytes" : 987654321,
          "blob_count" : 42,
          "completed_at" : "2023-11-14T22:13:20Z",
          "database_bytes" : 65536,
          "library_id" : "0123456789abcdef",
          "manifest_version" : 1,
          "schema_version" : "v15"
        }
        """)
    }

    @Test("encoding is deterministic — same manifest, same bytes")
    func encodingIsStable() throws {
        let encoder = BackupManifest.makeEncoder()
        #expect(try encoder.encode(sample()) == encoder.encode(sample()))
    }

    @Test("a manifest round-trips through JSON unchanged")
    func roundTrips() throws {
        let data = try BackupManifest.makeEncoder().encode(sample())
        #expect(try BackupManifest.makeDecoder()
            .decode(BackupManifest.self, from: data) == sample())
    }

    @Test("a manifest built from Date() round-trips EXACTLY")
    func subSecondPrecisionIsDropped() throws {
        // ISO-8601 without fractional seconds is what makes this file readable,
        // and it means sub-second precision cannot survive a write. Rather than
        // let a manifest be unequal to itself after a round trip — which would
        // silently break every "is this still the backup I wrote?" check — the
        // initializer truncates, so what's in memory is what's on disk.
        var manifest = sample()
        manifest.completedAt = Date(timeIntervalSince1970: 1_700_000_000.75)
        let rebuilt = BackupManifest(
            schemaVersion: manifest.schemaVersion, appVersion: manifest.appVersion,
            libraryID: manifest.libraryID, completedAt: manifest.completedAt,
            blobCount: manifest.blobCount, blobBytes: manifest.blobBytes,
            databaseBytes: manifest.databaseBytes)
        #expect(rebuilt.completedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let data = try BackupManifest.makeEncoder().encode(rebuilt)
        #expect(try BackupManifest.makeDecoder()
            .decode(BackupManifest.self, from: data) == rebuilt)
    }

    @Test("this build writes manifest_version 1")
    func currentVersion() {
        #expect(BackupManifest.currentVersion == 1)
        #expect(sample().manifestVersion == 1)
    }

    // MARK: - Files

    @Test("write then read gives back the same manifest")
    func fileRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("backup-manifest.json")
        try sample().write(to: url)
        #expect(try BackupManifest.read(from: url) == sample())
    }

    @Test("writing over a previous manifest replaces it wholesale")
    func writeReplaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("backup-manifest.json")
        try sample().write(to: url)

        var second = sample()
        second.blobCount = 43
        try second.write(to: url)

        // Not appended, not merged — a stale field surviving a rewrite would
        // make the manifest describe a backup that never existed.
        #expect(try BackupManifest.read(from: url).blobCount == 43)
    }

    @Test("an unparseable manifest throws rather than decoding to defaults")
    func garbageThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("backup-manifest.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try BackupManifest.read(from: url) }
    }

    @Test("a manifest missing a required field is rejected, not defaulted")
    func partialManifestThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Every field is non-optional on purpose: "0 blobs" and "field absent"
        // must not look the same to a reader deciding whether to restore.
        let url = directory.appendingPathComponent("backup-manifest.json")
        try Data(#"{"manifest_version": 1, "library_id": "0123456789abcdef"}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try BackupManifest.read(from: url) }
    }
}
