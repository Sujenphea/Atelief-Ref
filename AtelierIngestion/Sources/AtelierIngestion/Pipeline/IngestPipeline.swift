// AtelierIngestion — the single-image ingestion pipeline (chunk 4, A2 + P14)
//
// One image → stored blob + thumbnails + persisted asset. This is where the two
// load-bearing decisions live:
//   • A2 — blob-FIRST, then DB. Bytes are durable on disk (atomic rename in the
//     MediaStore) BEFORE `AppServices.ingest` writes the row, so no asset row
//     can ever reference a missing blob. A crash between the two leaves only a
//     harmless orphan blob, never a dangling row.
//   • P14 — hash-first short-circuit. We hash first; if the blob AND every
//     thumbnail tier already exist we do ZERO decode/thumbnail work and just
//     ensure the DB row + membership. Missing tiers (e.g. after a thumbnail
//     purge) are regenerated individually.
//
// `ingest` NEVER throws: any error from any stage is folded to
// `.failed(IngestError(mapping:))` (C8), so a single bad item is isolated as one
// outcome and the batch continues.

import Foundation
import AtelierCore

/// The stateless single-image ingestion pipeline (decisions A2 / P14).
///
/// `struct … Sendable` — it holds only the `Sendable` ``MediaStore``,
/// ``AppServices``, and the thumbnail tiers; no mutable state. All durability
/// lives in the filesystem (blobs/thumbnails) and the database (the asset row).
public struct IngestPipeline: Sendable {
    /// The content-addressed blob + thumbnail file store (A2 atomic writes).
    public let store: MediaStore
    /// The DB write surface — the per-item transaction (P15) that persists the
    /// asset + provenance + membership.
    public let services: AppServices
    /// The thumbnail tiers generated eagerly at ingest (A4). Defaults to every
    /// defined tier (128 / 512 / 1280).
    public let tiers: [ThumbnailTier]

    public init(
        store: MediaStore,
        services: AppServices,
        tiers: [ThumbnailTier] = ThumbnailTier.allCases
    ) {
        self.store = store
        self.services = services
        self.tiers = tiers
    }

    /// The JPEG extension all thumbnail tiers are stored under (matching
    /// ``ThumbnailGenerator``'s JPEG output).
    private static let thumbnailExtension = "jpg"

    /// Byte-derived metadata, trying the still-image path first and falling back to
    /// the AVFoundation video path for movie containers (which `CGImageSource`
    /// can't open). Image-first ordering keeps `ftyp`-based image formats (HEIC,
    /// AVIF) on the image path; the video path is attempted only when the image
    /// path fails AND the bytes actually sniff as a movie, so a corrupt image still
    /// surfaces its own `decodeFailed`/`unreadable` error rather than a misleading
    /// "unsupported".
    private static func extractMetadata(from bytes: Data) async throws -> ImageMetadata {
        do {
            return try ImageMetadata.extract(from: bytes)
        } catch let error as ImageError {
            guard MediaProbe.looksLikeMovie(bytes) else { throw error }
            return try await ImageMetadata.videoMetadata(from: bytes)
        }
    }

    /// Ingest one image. Never throws — any thrown error is folded to
    /// `.failed(IngestError(mapping:))` (C8).
    ///
    /// The stages, in blob-first order (A2) with the P14 short-circuit:
    /// 1. obtain the bytes (in-memory, or read the file URL);
    /// 2. content-hash them (`ContentHasher`, streamed-equivalent digest);
    /// 3. extract byte-derived metadata (dims / mime / kind / extension, C7);
    /// 4. **blob-first + P14**: store the blob only if absent, then generate +
    ///    store only the MISSING thumbnail tiers (a fully-present blob+tiers does
    ///    no decode/thumbnail work at all);
    /// 5. persist the asset + provenance + membership in one transaction (P15);
    /// 6. return `.ingested` with the resolved asset + dedup flag.
    public func ingest(_ input: IngestInput) async -> IngestOutcome {
        do {
            // 1. Bytes: in-memory as-is; a file URL is read now (a read failure
            //    — missing/unreadable file — maps to `.unreadableSource`).
            let bytes: Data
            switch input.source {
            case .data(let d):
                bytes = d
            case .fileURL(let url):
                do {
                    bytes = try Data(contentsOf: url)
                } catch {
                    throw IngestError.unreadableSource
                }
            }

            // 2. Content hash (address for the blob + thumbnails).
            let hash = ContentHasher.hash(bytes)

            // 3. Byte-derived metadata (throws ImageError → decode/unsupported/
            //    unreadable via IngestError(mapping:)). A movie container can't be
            //    read by CGImageSource, so it falls back to the AVFoundation path.
            let meta = try await Self.extractMetadata(from: bytes)

            // 4. Blob-first (A2) + hash-first short-circuit (P14).
            //    Store the blob only if it is not already present; a blob that
            //    exists is complete (MediaStore atomicity), so this is free dedup.
            if !store.hasBlob(hash: hash, fileExtension: meta.fileExtension) {
                do {
                    try store.storeBlob(bytes, hash: hash, fileExtension: meta.fileExtension)
                } catch {
                    throw IngestError.blobWriteFailed
                }
            }

            // Generate + store ONLY the missing thumbnail tiers. A tier already on
            // disk is skipped (no decode); a purged tier is regenerated. For a
            // video the thumbnail source is a poster frame rendered ONCE at the
            // largest tier (P14: only when a tier is actually missing).
            let missingTiers = tiers.filter {
                !store.hasThumbnail(
                    hash: hash, size: $0.rawValue, fileExtension: Self.thumbnailExtension)
            }
            if !missingTiers.isEmpty {
                let thumbnailSource = meta.kind == .video
                    ? try await ThumbnailGenerator.makeVideoPoster(
                        from: bytes, maxPixelSize: ThumbnailTier.large.rawValue)
                    : bytes
                for tier in missingTiers {
                    let thumbnail = try ThumbnailGenerator.makeThumbnail(
                        from: thumbnailSource, tier: tier)
                    do {
                        try store.storeThumbnail(
                            thumbnail, hash: hash, size: tier.rawValue,
                            fileExtension: Self.thumbnailExtension)
                    } catch {
                        throw IngestError.blobWriteFailed
                    }
                }
            }

            // 5. Persist in ONE transaction (P15). Only now — the blob is durable
            //    (A2), so the row can never reference a missing blob.
            let draft = AssetDraft(
                kind: meta.kind,
                blobHash: hash,
                mimeType: meta.mimeType,
                width: meta.width,
                height: meta.height,
                duration: meta.duration,
                fileSize: bytes.count,
                downloadState: .downloaded)
            let result = try await services.ingest(
                draft, from: input.provenance,
                into: input.collectionID, placement: input.placement)

            // 6. Success — the asset (new or deduped) with the dedup flag.
            return .ingested(asset: result.asset, deduplicated: result.wasDeduplicated)
        } catch {
            return .failed(IngestError(mapping: error))
        }
    }
}
