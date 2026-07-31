// AtelierIngestion — one off-device backup run, start to finish (008 · H5)
//
// The order below is the whole design, and it is chosen so that a run which
// dies at ANY point leaves the destination usable:
//
//   1. blobs first, database second. The database names blobs; a database copy
//      newer than the blob tree would reference files that aren't there yet.
//      Copying blobs first means the worst an interrupted run leaves is blobs
//      the (older) database doesn't mention — dead weight, not a dangling
//      reference. The next run's diff skips them, so they cost nothing twice.
//   2. the database lands as `library.sqlite.new`, is integrity-checked THERE,
//      and only then renames over `library.sqlite`. The previous good copy is
//      never deleted before its replacement is proven.
//   3. the manifest is written LAST. It is the run's commit record: a manifest
//      whose `completed_at` is present means everything above it finished.
//
// This type does no UI, holds no state, and takes its cancellation as a closure
// — the app layer owns progress publishing and the `CancelFlag`.

import AtelierCore
import Foundation

/// Runs one incremental backup of a live library into a chosen folder.
public struct BackupRunner: Sendable {
    private let services: AppServices
    private let source: MediaStore
    private let layout: BackupLayout
    private let appVersion: String

    /// - Parameters:
    ///   - services: the live library, for the referenced-blob set and the
    ///     database copy.
    ///   - source: the live blob store.
    ///   - layout: where the copy goes — already namespaced by library id.
    ///   - appVersion: recorded in the manifest, diagnostic only.
    public init(
        services: AppServices,
        source: MediaStore,
        layout: BackupLayout,
        appVersion: String
    ) {
        self.services = services
        self.source = source
        self.layout = layout
        self.appVersion = appVersion
    }

    /// Everything that can stop a run before it produces a manifest. Each case
    /// is a different thing to tell the user, for the same reason
    /// `FolderAccessError` has three.
    public enum RunError: Error, Equatable {
        /// The destination directories couldn't be created — the folder is
        /// read-only, or the volume vanished mid-run.
        case destinationUnwritable
        /// `VACUUM INTO` failed: most often no space left at the destination.
        case databaseCopyFailed
        /// The database copy landed but failed `PRAGMA integrity_check`. The
        /// previous copy is deliberately left in place.
        case databaseCopyCorrupt
        /// The verified copy couldn't be renamed over the previous one.
        case databaseInstallFailed
        /// The manifest — the run's commit record — couldn't be written.
        case manifestWriteFailed
    }

    /// Copy everything the destination is missing, then the database, then the
    /// manifest.
    ///
    /// Blob-level failures do NOT fail the run: they are reported in the
    /// returned ``BackupRunResult`` and retried by the next run, because the
    /// destination still lacks them. A run that cannot copy the DATABASE does
    /// fail, because a blob tree without a matching database restores nothing.
    ///
    /// - Parameter isCancelled: read before each blob and once before the
    ///   database step. Cancelling leaves a valid destination — just an older
    ///   one, since no manifest is written.
    @discardableResult
    public func run(
        maxConcurrent: Int = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil,
        now: Date = Date()
    ) async throws -> BackupRunResult {
        try makeDirectories()

        let referenced = try await services.referencedBlobs()
        let backupper = MediaBackupper(source: source, destination: layout.store)
        let pending = backupper.missing(from: referenced)
        let copy = await backupper.copy(
            pending, maxConcurrent: maxConcurrent,
            isCancelled: isCancelled, onProgress: onProgress)

        // A cancelled run stops HERE, before the database. Everything copied so
        // far is complete and content-addressed, so the next run resumes from it
        // — but no manifest is written, because the run did not finish.
        if copy.cancelled {
            return BackupRunResult(copy: copy, manifest: nil, cancelled: true)
        }

        let databaseBytes = try await installDatabase()
        let totals = destinationTotals()

        let manifest = BackupManifest(
            schemaVersion: AppServices.schemaVersion,
            appVersion: appVersion,
            libraryID: layout.libraryID,
            completedAt: now,
            blobCount: totals.count,
            blobBytes: totals.bytes,
            databaseBytes: databaseBytes)
        do {
            try manifest.write(to: layout.manifest)
        } catch {
            throw RunError.manifestWriteFailed
        }

        return BackupRunResult(copy: copy, manifest: manifest, cancelled: false)
    }

    // MARK: - Steps

    /// Create the destination root and its `blobs/` + `cache/` directories.
    /// `cache/` matters early: it is where the copier stages, and it must be on
    /// the same volume as the blobs for the rename to be atomic.
    private func makeDirectories() throws {
        let fm = FileManager.default
        do {
            for directory in [layout.root, layout.library.blobs, layout.library.cache] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            throw RunError.destinationUnwritable
        }
    }

    /// Write the database copy, verify it, and only then swap it in. Returns the
    /// installed copy's size in bytes.
    private func installDatabase() async throws -> Int64 {
        let fm = FileManager.default
        let incoming = layout.incomingDatabase

        // A previous run may have died between writing and renaming; `VACUUM
        // INTO` refuses an existing path, so clear the leftover first. It is
        // safe to discard by definition — it was never proven.
        try? fm.removeItem(at: incoming)

        do {
            try await services.snapshot(to: incoming)
        } catch {
            try? fm.removeItem(at: incoming)
            throw RunError.databaseCopyFailed
        }

        // Verify BEFORE the swap. A truncated copy (the destination filling up
        // is the realistic cause) must never replace a good one.
        let healthy = (try? AppServices.isHealthy(databaseFileAt: incoming)) ?? false
        guard healthy else {
            try? fm.removeItem(at: incoming)
            throw RunError.databaseCopyCorrupt
        }

        let size = Self.fileSize(of: incoming) ?? 0
        do {
            if fm.fileExists(atPath: layout.database.path) {
                // `replaceItemAt` is the atomic swap: the destination path holds
                // either the old copy or the new one, never nothing. A plain
                // remove-then-move has a window where a crash leaves no database
                // at all, which is the one outcome a backup may not produce.
                // (It requires the original to exist — hence the branch.)
                _ = try fm.replaceItemAt(layout.database, withItemAt: incoming)
            } else {
                // First run: nothing to replace, and a rename is already atomic.
                try fm.moveItem(at: incoming, to: layout.database)
            }
        } catch {
            try? fm.removeItem(at: incoming)
            throw RunError.databaseInstallFailed
        }
        return size
    }

    /// Count and total bytes of every blob file at the destination — what the
    /// backup HOLDS, which is what the manifest reports.
    private func destinationTotals() -> (count: Int, bytes: Int64) {
        let store = layout.store
        var count = 0
        var bytes: Int64 = 0
        for (hash, ext) in store.enumerateBlobFiles() {
            count += 1
            bytes += Self.fileSize(of: store.blobURL(hash: hash, fileExtension: ext)) ?? 0
        }
        return (count, bytes)
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return Int64(size)
    }
}

/// What one run did.
public struct BackupRunResult: Sendable, Equatable {
    /// The blob pass's tally.
    public var copy: BackupCopyResult
    /// The manifest written at the end — `nil` when the run was cancelled
    /// before it got there.
    public var manifest: BackupManifest?
    /// Whether the run stopped early at the user's request.
    public var cancelled: Bool

    public init(copy: BackupCopyResult, manifest: BackupManifest?, cancelled: Bool) {
        self.copy = copy
        self.manifest = manifest
        self.cancelled = cancelled
    }

    /// Whether the run finished with nothing left behind.
    public var isComplete: Bool { !cancelled && copy.isComplete }
}
