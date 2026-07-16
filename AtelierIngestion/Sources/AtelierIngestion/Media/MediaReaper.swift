// AtelierIngestion — reclaim the on-disk files of a deleted (orphaned) blob.
//
// The symmetric counterpart to the WRITE side of `IngestPipeline`: where the
// pipeline stores a blob (extension derived from the mime type) plus a thumbnail
// per `ThumbnailTier` (always JPEG), the reaper moves exactly those files to the
// Trash. It is the one place the delete-side media layout lives, so the
// "extension + tiers + jpg" knowledge isn't scattered.
//
// `AppServices.deleteAssets` (AtelierCore) decides WHICH blobs are reclaimable
// (dedup-safe reference counting) and returns them as `OrphanedBlob`; this turns
// each into file removals. Best-effort by design: the DB rows are already gone,
// so a file that fails to move is harmless leftover disk, never a correctness
// problem — hence per-file `try?` rather than aborting the batch.

import AtelierCore
import Foundation

/// Moves the on-disk files of orphaned blobs (the blob + all thumbnail tiers) to
/// the Trash. `Sendable` — it only wraps a `Sendable` ``MediaStore`` and holds no
/// mutable state — so it can run off the main actor.
public struct MediaReaper: Sendable {
    private let store: MediaStore

    public init(store: MediaStore) {
        self.store = store
    }

    /// Reap a batch of orphaned blobs, returning the Trash locations of every
    /// file actually moved (for logging / test cleanup). Order is not meaningful.
    @discardableResult
    public func reap(_ orphans: [OrphanedBlob]) -> [URL] {
        orphans.flatMap { reap(blobHash: $0.blobHash, mimeType: $0.mimeType) }
    }

    /// Trash one orphaned blob's files: the blob (its stored extension recovered
    /// from `mimeType`, matching how readers locate it) and every
    /// ``ThumbnailTier`` (`@<size>.jpg`). Best-effort — a per-file failure is
    /// swallowed so one bad file can't strand the rest. Returns the Trash URLs of
    /// the files that were present and moved.
    @discardableResult
    public func reap(blobHash: String, mimeType: String) -> [URL] {
        var trashed: [URL] = []
        let blobExtension = ImageMetadata.fileExtension(forMIMEType: mimeType)
        if let url = try? store.removeBlob(hash: blobHash, fileExtension: blobExtension) {
            trashed.append(url)
        }
        for tier in ThumbnailTier.allCases {
            if let url = try? store.removeThumbnail(
                hash: blobHash, size: tier.rawValue, fileExtension: Self.thumbnailExtension) {
                trashed.append(url)
            }
        }
        return trashed
    }

    /// Reap every stored blob whose hash is NOT in `referenced` — the launch
    /// orphan-GC (010 · delete-undo). Because a recoverable delete DEFERS reaping
    /// (so an in-session undo finds the bytes), a delete that was never undone
    /// leaves orphans; at launch the undo history is empty, so any on-disk blob no
    /// asset references is genuinely unreachable and safe to reclaim. Diffs the
    /// on-disk set against `referenced` and Trashes each orphan's blob + every
    /// thumbnail tier. Best-effort per file. Returns the Trash locations of every
    /// file moved (like ``reap(blobHash:mimeType:)``) — for logging / test cleanup.
    @discardableResult
    public func reapOrphanedBlobs(referenced: Set<String>) -> [URL] {
        var trashed: [URL] = []
        for (hash, ext) in store.enumerateBlobFiles() where !referenced.contains(hash) {
            if let url = try? store.removeBlob(hash: hash, fileExtension: ext) {
                trashed.append(url)
            }
            for tier in ThumbnailTier.allCases {
                if let url = try? store.removeThumbnail(
                    hash: hash, size: tier.rawValue, fileExtension: Self.thumbnailExtension) {
                    trashed.append(url)
                }
            }
        }
        return trashed
    }

    /// The extension every thumbnail tier is stored under (JPEG), mirroring
    /// `IngestPipeline`'s write side. Kept here so the reaper stays the single
    /// home of the delete-side layout.
    private static let thumbnailExtension = "jpg"
}
