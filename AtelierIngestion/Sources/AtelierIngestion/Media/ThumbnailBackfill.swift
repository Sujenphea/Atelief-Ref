// AtelierIngestion — regenerate the thumbnail tiers a blob is missing (016 · A).
//
// The symmetric counterpart of `MediaReaper`: where the reaper removes a blob's
// derived files, this puts them back. Both exist because `thumbnails/` is
// DERIVED — excluded from Time Machine (008 H2), trashed alongside a reaped
// blob, purgeable at any time — and derived data that can't be rebuilt on
// demand is just data you lost slowly.
//
// It writes ONLY into `thumbnails/`. It never touches `blobs/`, never writes to
// the database, and never deletes anything: the worst outcome of running it on
// a healthy library is that it finds nothing to do.
//
// The tier logic is `IngestPipeline`'s, on purpose and to the letter — the same
// "only the missing tiers", the same single video poster rendered once at the
// largest tier and fed back through the image path for the smaller ones. This
// is the same work the pipeline would have done; the only difference is that
// nothing is being ingested.

import AtelierCore
import Foundation

/// Regenerates missing thumbnail tiers for blobs that still have their bytes.
/// `Sendable` — it wraps only a `Sendable` ``MediaStore`` — so it runs off the
/// main actor.
public struct ThumbnailBackfill: Sendable {

    /// What a run did. Honest about all three outcomes: a report that says only
    /// "done" can't distinguish a healthy library from one where every blob is
    /// unreadable (004's batch-outcome lesson, 016's importer-report rule).
    public struct Result: Sendable, Equatable {
        /// Thumbnail FILES written (blobs × missing tiers).
        public var generated: Int = 0
        /// Blobs that were missing at least one tier and now have them all.
        public var repaired: Int = 0
        /// Blobs skipped because their bytes couldn't be read or decoded — a
        /// blob whose file is gone, or one whose bytes aren't renderable. Not a
        /// failure of the run: there is nothing to regenerate FROM.
        public var skipped: Int = 0
        /// Blobs that already had every tier. The healthy case.
        public var alreadyComplete: Int = 0

        public init() {}

        /// Whether the run changed anything on disk.
        public var didWork: Bool { generated > 0 }
    }

    /// Thumbnails are always JPEG, mirroring `IngestPipeline`'s write side and
    /// `MediaReaper`'s delete side.
    private static let thumbnailExtension = "jpg"

    private let store: MediaStore

    public init(store: MediaStore) {
        self.store = store
    }

    /// Fill in every missing tier for `blobs`.
    ///
    /// `[BlobRef]` rather than a hash set: finding a blob's FILE needs the mime
    /// type (it names the stored extension), and rendering the poster frame for
    /// a video needs to know it IS a video. `AppServices.referencedBlobs()` is
    /// the call that supplies both.
    ///
    /// - Parameters:
    ///   - isCancelled: polled once per blob — a Stop lands within one blob's
    ///     work rather than at the end of the library.
    ///   - onProgress: `0…1` over `blobs`, throttled to whole percents.
    /// - Throws: `CancellationError` only. Per-blob failures are counted as
    ///   `skipped` and the run continues — one unreadable file must not strand
    ///   the thousands behind it (`MediaReaper`'s best-effort stance).
    public func run(
        blobs: [BlobRef],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        var result = Result()
        var lastPercent = -1
        let total = blobs.count

        for (index, blob) in blobs.enumerated() {
            if isCancelled() { throw CancellationError() }

            let blobExtension = ImageMetadata.fileExtension(forMIMEType: blob.mimeType)
            let missing = ThumbnailTier.allCases.filter {
                !store.hasThumbnail(
                    hash: blob.blobHash, size: $0.rawValue,
                    fileExtension: Self.thumbnailExtension)
            }

            if missing.isEmpty {
                result.alreadyComplete += 1
            } else if let bytes = try? store.readBlob(
                hash: blob.blobHash, fileExtension: blobExtension) {
                let written = await generate(missing, from: bytes, blob: blob)
                if written == missing.count {
                    result.repaired += 1
                } else {
                    // Some tiers landed, some didn't — the blob is still
                    // incomplete, so it is a skip WITH progress, not a repair.
                    result.skipped += 1
                }
                result.generated += written
            } else {
                // No bytes on disk: this blob is the orphan sweep's problem or
                // a failed download's, not the thumbnailer's.
                result.skipped += 1
            }

            if total > 0 {
                let percent = Int(Double(index + 1) / Double(total) * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    onProgress(Double(index + 1) / Double(total))
                }
            }
        }
        onProgress(1)
        return result
    }

    /// Render + store `tiers` for one blob, returning how many files landed.
    /// A video's poster frame is rendered ONCE at the largest tier and reused as
    /// the source for the smaller ones — decoding the movie per tier would cost
    /// three seeks for one frame.
    private func generate(
        _ tiers: [ThumbnailTier], from bytes: Data, blob: BlobRef
    ) async -> Int {
        let source: Data
        if blob.mimeType.hasPrefix("video/") {
            guard let poster = try? await ThumbnailGenerator.makeVideoPoster(
                from: bytes, maxPixelSize: ThumbnailTier.large.rawValue) else { return 0 }
            source = poster
        } else {
            source = bytes
        }

        var written = 0
        for tier in tiers {
            guard let thumbnail = try? ThumbnailGenerator.makeThumbnail(
                from: source, tier: tier) else { continue }
            if (try? store.storeThumbnail(
                thumbnail, hash: blob.blobHash, size: tier.rawValue,
                fileExtension: Self.thumbnailExtension)) != nil {
                written += 1
            }
        }
        return written
    }
}
