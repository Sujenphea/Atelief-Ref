// AtelierIngestion — copy blob files between two stores (008 · H5)
//
// The symmetric sibling of `MediaReaper`: a `Sendable` struct over two
// `MediaStore`s that moves bytes one way, best-effort per file, reporting what
// it could not do rather than aborting the batch. Where the reaper reclaims,
// this one preserves.
//
// DIRECTION-AGNOSTIC by construction (008 · H5c). Backup runs it live→backup and
// drives the diff from the DATABASE (`missing(from:)`, over the blobs assets
// reference); restore runs it backup→live and drives the diff from the
// FILE TREE (`missingFiles()`, over the blobs the backup holds). One copy loop
// either way — the two directions differ only in what they are asked to move,
// which is the property that makes "restore is backup in reverse" true rather
// than aspirational.
//
// The whole design rests on one property, inherited from `MediaStore` and not
// re-invented here: **a blob file that exists is complete** (A2). That is what
// makes the diff sound. A run copies only the hashes the destination lacks, so
// "already there" has to mean "already there IN FULL" — otherwise an
// interrupted run would leave a truncated file that every future run then skips,
// and the backup would be quietly, permanently wrong. `storeBlobFile` stages
// into the destination's own `cache/` and renames into place, so an interrupted
// copy leaves a stray temp file and nothing else.
//
// Nothing here hashes anything. Verification (re-hashing a sample of what
// landed) is a separate, explicitly-priced step: on a synced destination the
// files may be dataless, and reading them back forces a download.

import AtelierCore
import Foundation

/// One blob as the FILESYSTEM names it: the hash, and the extension the bytes
/// were actually written with.
///
/// Deliberately not `BlobRef`. `BlobRef` carries a mime type, from which the
/// extension is *derived* (`ImageMetadata.fileExtension(forMIMEType:)`, whose
/// answer for `image/jpeg` is "jpeg", not "jpg") — that derivation belongs to
/// the database side of the world. When the file tree is what's being read, the
/// extension is already known and re-deriving it could only introduce a
/// disagreement with the file that is sitting right there.
public struct BlobFile: Sendable, Equatable, Hashable {
    /// The content hash — the filename stem, and the shard key.
    public let hash: String
    /// The extension, without a leading dot. Empty for the dotless path
    /// `MediaStore` writes when a mime type can't be resolved.
    public let fileExtension: String

    public init(hash: String, fileExtension: String) {
        self.hash = hash
        self.fileExtension = fileExtension
    }
}

/// Copies blob files from one store into another — live→backup for a backup
/// run, backup→live for a restore.
///
/// `struct … Sendable` — two `Sendable` stores and no mutable state, so the copy
/// can run off the main actor.
public struct MediaBackupper: Sendable {
    private let source: MediaStore
    private let destination: MediaStore

    public init(source: MediaStore, destination: MediaStore) {
        self.source = source
        self.destination = destination
    }

    // MARK: - Diff

    /// The subset of `referenced` the destination does not already hold — the
    /// work an incremental run has to do.
    ///
    /// Duplicate hashes collapse to one entry. `AppServices.referencedBlobs()`
    /// already groups by hash, so this is belt-and-braces rather than load-
    /// bearing; it costs a set and removes any chance of two entries racing to
    /// install the same destination path.
    public func missing(from referenced: [BlobRef]) -> [BlobRef] {
        var seen = Set<String>()
        var result: [BlobRef] = []
        for ref in referenced where seen.insert(ref.blobHash).inserted {
            let ext = ImageMetadata.fileExtension(forMIMEType: ref.mimeType)
            if !destination.hasBlob(hash: ref.blobHash, fileExtension: ext) {
                result.append(ref)
            }
        }
        return result
    }

    /// The blob FILES the source holds that the destination lacks — the same
    /// diff driven by the file tree instead of the database (008 · H5c).
    ///
    /// Restore needs this direction because the database that names the blobs is
    /// the very thing being restored: reading it would mean opening the backup's
    /// `library.sqlite`, and `LibraryDatabase.init` MIGRATES what it opens — a
    /// restore that quietly rewrote the backup it was reading from would destroy
    /// the artifact it exists to protect. Enumerating the tree is also honest
    /// about extensions: the filename carries the one the bytes were actually
    /// written with, so no mime→extension guess can drift.
    ///
    /// The result is a SUPERSET of what the restored database will reference —
    /// a backup keeps blobs the library later deleted (deletes deliberately do
    /// not propagate), and those come back too. That is the safe direction: a
    /// blob too many is reclaimed by a later orphan GC, a blob too few is an
    /// item that renders empty forever.
    ///
    /// Sorted by hash so a run's order — and therefore its progress — is
    /// reproducible rather than filesystem-dependent.
    public func missingFiles() -> [BlobFile] {
        var seen = Set<BlobFile>()
        var result: [BlobFile] = []
        for (hash, ext) in source.enumerateBlobFiles() {
            let file = BlobFile(hash: hash, fileExtension: ext)
            guard seen.insert(file).inserted else { continue }
            if !destination.hasBlob(hash: hash, fileExtension: ext) {
                result.append(file)
            }
        }
        return result.sorted { $0.hash < $1.hash }
    }

    // MARK: - Copy

    /// Copy every ref in `refs` to the destination, at most `maxConcurrent` at a
    /// time, reporting progress as each file lands.
    ///
    /// Best-effort per file, like the reaper: a blob whose bytes are missing at
    /// the source, or whose copy fails, is RECORDED and the batch continues. One
    /// unreadable file must not cost the user the other ten thousand — and the
    /// next run retries it for free, because the destination still lacks it.
    ///
    /// - Parameter isCancelled: read before each file. A caller on
    ///   `Task.detached` does not inherit task cancellation, so it must pass its
    ///   own flag (the `CancelFlag` precedent); `runBounded`'s internal
    ///   `Task.isCancelled` check covers the non-detached case.
    /// - Parameter onProgress: `(completed, total)`, delivered monotonically.
    public func copy(
        _ refs: [BlobRef],
        maxConcurrent: Int = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> BackupCopyResult {
        // The mime→extension derivation happens exactly here, once: below this
        // line both directions are the same list of files.
        await copyFiles(
            refs.map {
                BlobFile(
                    hash: $0.blobHash,
                    fileExtension: ImageMetadata.fileExtension(forMIMEType: $0.mimeType))
            },
            maxConcurrent: maxConcurrent, isCancelled: isCancelled, onProgress: onProgress)
    }

    /// The copy loop itself, over files named the way the filesystem names them.
    ///
    /// Identical semantics to ``copy(_:maxConcurrent:isCancelled:onProgress:)``
    /// — best-effort per file, resumable, progress delivered monotonically —
    /// and the single implementation both directions run through.
    public func copyFiles(
        _ files: [BlobFile],
        maxConcurrent: Int = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> BackupCopyResult {
        guard !files.isEmpty else { return BackupCopyResult() }

        let reporter = ProgressReporter(total: files.count, onProgress: onProgress)
        let source = source
        let destination = destination

        let outcomes = await runBounded(files, maxConcurrent: maxConcurrent) { _, file in
            let outcome: BlobCopyOutcome = isCancelled()
                ? .skipped
                : Self.copyOne(file, from: source, to: destination)
            await reporter.report()
            return outcome
        }

        // A `nil` slot is an item `runBounded` never launched (cancelled before
        // its turn); `.skipped` is one that reached the flag. Both mean "not
        // attempted", which is what makes the run resumable.
        var result = BackupCopyResult()
        for (file, outcome) in zip(files, outcomes) {
            switch outcome ?? .skipped {
            case .copied(let bytes):
                result.copied += 1
                result.bytesCopied += bytes
            case .alreadyPresent:
                result.alreadyPresent += 1
            case .missingAtSource:
                result.missingAtSource.append(file.hash)
            case .failed:
                result.failed.append(file.hash)
            case .skipped:
                result.skipped += 1
            }
        }
        // Cancellation is reported by what it COST, not by the flag: a cancel
        // that arrives once the last file is already in flight skips nothing,
        // and that pass really did finish its work.
        result.cancelled = result.skipped > 0
        return result
    }

    /// Copy one blob. `static` so the concurrent closure captures two `Sendable`
    /// stores rather than `self`.
    private static func copyOne(
        _ file: BlobFile, from source: MediaStore, to destination: MediaStore
    ) -> BlobCopyOutcome {
        let origin = source.blobURL(hash: file.hash, fileExtension: file.fileExtension)

        // A referenced row whose file is gone is a real state (a blob deleted
        // out from under the library), and it is the DB that is authoritative —
        // so report the miss and move on. Never crash, never abort the batch.
        guard let size = fileSize(of: origin) else { return .missingAtSource }

        if destination.hasBlob(hash: file.hash, fileExtension: file.fileExtension) {
            // Raced with another run, or the caller passed an unfiltered list.
            return .alreadyPresent
        }

        do {
            try destination.storeBlobFile(
                copyingFrom: origin, hash: file.hash, fileExtension: file.fileExtension)
            return .copied(size)
        } catch {
            return .failed
        }
    }

    /// The size of a regular file at `url`, or `nil` if it isn't one (absent,
    /// or a directory).
    private static func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    /// What happened to one blob.
    private enum BlobCopyOutcome: Sendable {
        case copied(Int64)
        case alreadyPresent
        case missingAtSource
        case failed
        case skipped
    }
}

/// The tally of one copy pass.
///
/// Every field is a count or a list of hashes — nothing here is a `URL` or an
/// `Error`, so it crosses actor boundaries and reaches a UI unchanged.
public struct BackupCopyResult: Sendable, Equatable {
    /// Files whose bytes this pass moved.
    public var copied = 0
    /// Total bytes moved by this pass (not the destination's total).
    public var bytesCopied: Int64 = 0
    /// Files the destination already had — a re-run's normal outcome, and zero
    /// on a pass fed by ``MediaBackupper/missing(from:)``.
    public var alreadyPresent = 0
    /// Referenced blobs with no file at the source. The DB is authoritative, so
    /// these are a source problem to surface, not a backup failure.
    public var missingAtSource: [String] = []
    /// Blobs whose copy threw — the destination filling up, a read error. The
    /// next run retries them, since the destination still lacks them.
    public var failed: [String] = []
    /// Files not attempted because the run was cancelled.
    public var skipped = 0
    /// Whether the pass stopped early.
    public var cancelled = false

    public init() {}

    /// Whether every file this pass was given is now at the destination.
    public var isComplete: Bool {
        !cancelled && failed.isEmpty && missingAtSource.isEmpty
    }
}
