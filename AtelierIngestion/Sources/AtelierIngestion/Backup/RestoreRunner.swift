// AtelierIngestion — one restore run, start to finish (008 · H5c)
//
// `BackupRunner` read backwards, and it ends by handing its result to a seam
// that already exists rather than building a second one.
//
//   1. refuse first, before anything is touched. A manifest from a future
//      build, or a database from a newer schema, is not something to half-apply
//      and discover later — this build cannot know what a migration it has
//      never seen did to that file.
//   2. blobs first, database second — the same order and the same reason as a
//      backup run. The database names blobs; installing it before the bytes
//      exist would mean a window where the library references files that aren't
//      there. Copying blobs first means the worst an interrupted restore leaves
//      is blobs the (unchanged) live database doesn't mention: dead weight the
//      next orphan GC reclaims, never a dangling reference. Every copy is
//      content-addressed and staged-then-renamed, so this step is safe with the
//      app running and resumable if it stops.
//   3. the database copy lands in the live `snapshots/` directory under a
//      HIDDEN staging name, is integrity-checked THERE, and only then renames
//      into a valid `SnapshotFile` name. An unhealthy copy is therefore never
//      visible as a snapshot, let alone offered as a restore candidate.
//
// And then it stops. Installing the database over the live one is not this
// type's job and must not become it: `SnapshotManager.stageRestore` →
// `.pending-restore` → relaunch → `applyPendingRestore` is atomic, rollback-safe
// and covered by its own failure suite, and the backup's database has just
// become an ordinary snapshot, so it goes through that path like any other. One
// swap mechanism in the app, not two.

import AtelierCore
import Foundation

/// Restores a library from one ``BackupSource`` into a live library.
public struct RestoreRunner: Sendable {
    private let source: BackupSource
    private let live: MediaStore
    private let snapshotsDirectory: URL
    private let schemaVersion: String

    /// - Parameters:
    ///   - source: the backup to restore, as ``BackupCatalog`` found it.
    ///   - live: the live blob store the bytes are copied INTO.
    ///   - snapshotsDirectory: the live library's `snapshots/` — where the
    ///     backup's database lands so the shipped restore seam can take it.
    ///   - schemaVersion: what this build migrates to, for the refusal check.
    ///     Injectable so the "backup is from a newer build" case is testable
    ///     without inventing a future migration.
    public init(
        source: BackupSource,
        live: MediaStore,
        snapshotsDirectory: URL,
        schemaVersion: String = AppServices.schemaVersion
    ) {
        self.source = source
        self.live = live
        self.snapshotsDirectory = snapshotsDirectory
        self.schemaVersion = schemaVersion
    }

    /// Everything that can stop a restore. Each case is a different thing to
    /// tell the user, for the same reason ``BackupRunner/RunError`` has five.
    public enum RestoreError: Error, Equatable {
        /// The backup folder has no `library.sqlite` — the run that made it
        /// never got that far, or the file was removed by hand.
        case databaseMissing
        /// The manifest declares a shape this build doesn't know.
        case manifestTooNew
        /// The backup was written by a build with a newer schema. Carries the
        /// version so the message can name it.
        case schemaTooNew(String)
        /// The live `snapshots/` directory couldn't be created or written.
        case snapshotsUnwritable
        /// Copying the database out of the backup failed — an unplugged drive,
        /// a dataless file that wouldn't download, no space locally.
        case databaseUnreadable
        /// The copy landed but failed `PRAGMA integrity_check`. Nothing is
        /// staged, and the copy is deleted rather than left to look restorable.
        case databaseUnhealthy
    }

    // MARK: - Refusal

    /// Why `manifest` must not be restored by a build at `schemaVersion`, or
    /// `nil` if it can be. Pure, so both version rules are directly testable.
    ///
    /// An UNPARSEABLE version on either side is not a refusal. The rule being
    /// enforced is "newer than me", and "I can't tell" is not evidence of that;
    /// refusing on it would brick restore for anyone whose version string
    /// convention moved, which is a self-inflicted outage in the one feature
    /// people reach for when everything else has already gone wrong.
    public static func refusal(
        for manifest: BackupManifest, schemaVersion: String
    ) -> RestoreError? {
        if manifest.manifestVersion > BackupManifest.currentVersion { return .manifestTooNew }
        guard let backup = schemaOrdinal(manifest.schemaVersion),
              let local = schemaOrdinal(schemaVersion),
              backup > local
        else { return nil }
        return .schemaTooNew(manifest.schemaVersion)
    }

    /// The integer in a `"v18"`-style schema identifier, or `nil`.
    static func schemaOrdinal(_ version: String) -> Int? {
        guard version.hasPrefix("v") else { return nil }
        return Int(version.dropFirst())
    }

    // MARK: - The run

    /// Copy the backup's blobs into the live store, then its database into the
    /// live `snapshots/` as a restorable snapshot.
    ///
    /// Blob-level failures do NOT fail the restore: they are reported in the
    /// result and retried for free by a re-run, because the live store still
    /// lacks them. A restore that cannot install the DATABASE does fail — blobs
    /// without the database that names them restore nothing.
    ///
    /// - Parameter isCancelled: read before each blob and once before the
    ///   database step. Cancelling leaves the live library completely unchanged
    ///   apart from extra blob files, and stages nothing.
    /// - Returns: the result, whose ``RestoreRunResult/snapshot`` is the file to
    ///   hand to `SnapshotManager.stageRestore` — `nil` when cancelled.
    public func run(
        maxConcurrent: Int = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil,
        now: Date = Date()
    ) async throws -> RestoreRunResult {
        if let refusal = Self.refusal(for: source.manifest, schemaVersion: schemaVersion) {
            throw refusal
        }
        guard FileManager.default.fileExists(atPath: source.layout.database.path) else {
            throw RestoreError.databaseMissing
        }
        do {
            try FileManager.default.createDirectory(
                at: snapshotsDirectory, withIntermediateDirectories: true)
        } catch {
            throw RestoreError.snapshotsUnwritable
        }

        let backupper = MediaBackupper(source: source.layout.store, destination: live)
        let pending = backupper.missingFiles()
        let copy = await backupper.copyFiles(
            pending, maxConcurrent: maxConcurrent,
            isCancelled: isCancelled, onProgress: onProgress)

        // A cancelled restore stops HERE, before the database. Every blob copied
        // so far is complete and content-addressed, so a later run resumes from
        // it — and because nothing is staged, the live library is exactly as the
        // user left it.
        if copy.cancelled {
            return RestoreRunResult(copy: copy, snapshot: nil, cancelled: true)
        }

        let snapshot = try installSnapshot(now: now)
        return RestoreRunResult(copy: copy, snapshot: snapshot, cancelled: false)
    }

    // MARK: - Steps

    /// Copy the backup's database into the live `snapshots/` directory and
    /// return the snapshot file it became.
    ///
    /// The staging name is DOT-PREFIXED and deliberately not a parseable
    /// `SnapshotFile` name: between the copy landing and its integrity check
    /// passing, the file must be invisible to `SnapshotManager.list()`, or a
    /// user opening the snapshots sheet at the wrong moment could be offered a
    /// half-copied database to restore from.
    private func installSnapshot(now: Date) throws -> URL {
        let fm = FileManager.default
        let staging = snapshotsDirectory.appendingPathComponent(
            ".restore-incoming-\(UUID().uuidString).sqlite", isDirectory: false)
        try? fm.removeItem(at: staging)

        do {
            try fm.copyItem(at: source.layout.database, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw RestoreError.databaseUnreadable
        }

        // Verify BEFORE it can be named a snapshot. A truncated copy — a drive
        // pulled mid-restore is the realistic cause — must never be offered as
        // something to replace the live library with.
        let healthy = (try? AppServices.isHealthy(databaseFileAt: staging)) ?? false
        guard healthy else {
            try? fm.removeItem(at: staging)
            throw RestoreError.databaseUnhealthy
        }

        // Named `.manual` at TODAY's date, not the backup's. The reason is
        // retention, which prunes by date: a backup from three months ago named
        // with its own timestamp would arrive already outside the rolling window
        // and could be pruned between staging and the relaunch that applies it,
        // turning a restore into a silent no-op. The file really was created
        // now, and the backup's own date is what the confirmation names.
        let destination = try uniqueSnapshotURL(now: now)
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw RestoreError.databaseUnreadable
        }
        return destination
    }

    /// A snapshot URL that is not already taken. `SnapshotFile.makeURL` carries
    /// a random id so a collision is vanishingly unlikely, but the neighbouring
    /// contract (`AppServices.snapshot(to:)` refuses to overwrite) is that a
    /// database write never lands on an existing path, and a restore has no
    /// business being the one place that does.
    private func uniqueSnapshotURL(now: Date) throws -> URL {
        for _ in 0 ..< 8 {
            let url = SnapshotFile.makeURL(in: snapshotsDirectory, reason: .manual, date: now)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw RestoreError.databaseUnreadable
    }
}

/// What one restore did.
public struct RestoreRunResult: Sendable, Equatable {
    /// The blob pass's tally — the same type a backup run reports, because it
    /// is the same pass in the other direction.
    public var copy: BackupCopyResult
    /// The snapshot the backup's database became, ready for `stageRestore`.
    /// `nil` when the run was cancelled before it got there.
    public var snapshot: URL?
    /// Whether the run stopped early at the user's request.
    public var cancelled: Bool

    public init(copy: BackupCopyResult, snapshot: URL?, cancelled: Bool) {
        self.copy = copy
        self.snapshot = snapshot
        self.cancelled = cancelled
    }

    /// Whether every blob landed AND there is a database to stage.
    public var isComplete: Bool { !cancelled && copy.isComplete && snapshot != nil }
}
