// AtelierIngestion — what a backup destination holds, and what wrote it (008 · H5)
//
// The one machine-readable file in a backup folder. It is NOT an index of the
// contents — the blob tree is content-addressed and the database copy is
// authoritative, so a manifest that listed every hash would be a second source
// of truth that could disagree with the first. It answers the questions a
// restore (or a support conversation) actually asks: is this backup mine, how
// recent is it, how big, and can this build of the app read it.
//
// Versioned on TWO axes, because they move independently:
//   • `manifestVersion` — the shape of this file. Bumped when a field's meaning
//     changes; a reader that doesn't recognise the number must refuse rather
//     than guess.
//   • `schemaVersion` — the database migration the copy was written from. A
//     newer build migrates it forward on restore; an OLDER build must refuse,
//     since it cannot know what a future migration did.

import Foundation

/// The `backup-manifest.json` written at the end of every successful run.
public struct BackupManifest: Codable, Equatable, Sendable {

    /// The manifest shape this build writes.
    public static let currentVersion = 1

    /// The shape of this file (see the type's note on the two version axes).
    public var manifestVersion: Int

    /// The database migration identifier the copy was written from ("v16").
    public var schemaVersion: String

    /// The app build that wrote it — diagnostic only; nothing branches on it.
    public var appVersion: String

    /// Which library this backs up (``LibraryIdentity``), repeated from the
    /// directory name so a folder moved by hand can still be identified.
    public var libraryID: String

    /// When the run that wrote this finished, truncated to whole seconds (see
    /// ``init(manifestVersion:schemaVersion:appVersion:libraryID:completedAt:blobCount:blobBytes:databaseBytes:)``).
    public var completedAt: Date

    /// Blob files present at the destination when the run finished — the total,
    /// not this run's copies, so the number describes the backup rather than the
    /// last increment.
    public var blobCount: Int

    /// Total bytes of those blob files.
    public var blobBytes: Int64

    /// Size of the database copy.
    public var databaseBytes: Int64

    /// `completedAt` is TRUNCATED TO WHOLE SECONDS.
    ///
    /// The wire format is ISO-8601 without fractional seconds — chosen because a
    /// human opening this file should be able to read the timestamp. Keeping
    /// sub-second precision in memory would mean a manifest that is not equal to
    /// itself after a write and a read, so every "is the destination still the
    /// one I wrote?" comparison would be quietly false. Truncating here makes
    /// the in-memory value and the on-disk value the same value.
    public init(
        manifestVersion: Int = BackupManifest.currentVersion,
        schemaVersion: String,
        appVersion: String,
        libraryID: String,
        completedAt: Date,
        blobCount: Int,
        blobBytes: Int64,
        databaseBytes: Int64
    ) {
        self.manifestVersion = manifestVersion
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.libraryID = libraryID
        self.completedAt = Date(
            timeIntervalSince1970: completedAt.timeIntervalSince1970.rounded(.down))
        self.blobCount = blobCount
        self.blobBytes = blobBytes
        self.databaseBytes = databaseBytes
    }

    /// snake_case on disk. Spelled out rather than left to a key-encoding
    /// strategy so the wire names are visible at the type and cannot drift when
    /// a property is renamed — this file is a contract with future readers.
    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case libraryID = "library_id"
        case completedAt = "completed_at"
        case blobCount = "blob_count"
        case blobBytes = "blob_bytes"
        case databaseBytes = "database_bytes"
    }

    // MARK: - Serialization

    /// Deterministic: sorted keys and ISO-8601 dates, so the same manifest
    /// always produces byte-identical output. That is what lets a test pin the
    /// contract against a golden string and fail loudly when the shape moves.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Write to `url`, replacing any previous manifest. `.atomic` so a run
    /// interrupted here leaves the PREVIOUS manifest intact rather than a
    /// truncated one — a destination whose manifest won't parse looks
    /// indistinguishable from a corrupt backup.
    public func write(to url: URL) throws {
        try Self.makeEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Read a manifest, or throw if it is absent or unparseable.
    public static func read(from url: URL) throws -> BackupManifest {
        try makeDecoder().decode(BackupManifest.self, from: Data(contentsOf: url))
    }
}
