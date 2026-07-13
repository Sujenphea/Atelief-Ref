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
    /// Optional per-ingest phase-timing sink (Phase 8, 16A) — the app logs slow
    /// thumbnail phases here to reveal a stall. Nil ⇒ timing is measured but not
    /// emitted (a handful of cheap clock reads, no behaviour change).
    private let timing: (@Sendable (IngestTiming) -> Void)?

    public init(
        store: MediaStore,
        services: AppServices,
        tiers: [ThumbnailTier] = ThumbnailTier.allCases,
        timing: (@Sendable (IngestTiming) -> Void)? = nil
    ) {
        self.store = store
        self.services = services
        self.tiers = tiers
        self.timing = timing
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
        // Branch once on what the item carries (003 · C3): a media-less content
        // draft skips every byte stage and goes straight to `ingestContent`;
        // a content draft WITH a card image runs the blob-first stages for the
        // image AND persists via `ingestContent(_:blob:)` (Option 3); plain bytes
        // take the blob-first pipeline.
        switch input.source {
        case .content(let draft):
            return await ingestContent(draft, input: input)
        case .contentWithBytes(let draft, let image):
            return await ingestContentWithBytes(draft, image, input: input)
        case .bytes(let byteSource):
            return await ingestBytes(byteSource, input: input)
        }
    }

    /// Persist a MEDIA-LESS item (003 · C3) — no bytes, so no hash / blob /
    /// thumbnail work: the draft's substance is its ``AssetPayload``. The funnel
    /// (`AppServices.ingestContent`) validates the draft and dedups by kind; a
    /// rejected draft folds to `.failed(.persistence(...))` like any other stage.
    private func ingestContent(
        _ draft: AssetContentDraft, input: IngestInput
    ) async -> IngestOutcome {
        do {
            let result = try await services.ingestContent(
                draft, from: input.provenance,
                into: input.collectionID, placement: input.placement)
            return .ingested(asset: result.asset, deduplicated: result.wasDeduplicated)
        } catch {
            return .failed(IngestError(mapping: error))
        }
    }

    /// The result of the shared blob-first storage stage (A2 + P14) — everything
    /// the persist step and the phase-timing need. `createdBlob` is set ONLY when
    /// THIS call wrote a brand-new blob (so it can be reclaimed before any DB row
    /// exists, G2); it is `nil` on the P14 short-circuit (the blob already existed).
    private struct StoredBytes {
        let hash: String
        let meta: ImageMetadata
        let bytesCount: Int
        let createdBlob: (hash: String, fileExtension: String)?
        let blobExisted: Bool
        let tiersGenerated: Int
        let afterMetadata: ContinuousClock.Instant
        let afterThumbnails: ContinuousClock.Instant
    }

    /// The blob-first (A2) + P14 storage stage, shared by the byte path and the
    /// content-with-card-image path (Option 3): read the bytes, hash them, extract
    /// byte metadata, then store the blob + any MISSING thumbnail tiers only when
    /// absent. Reclaims a brand-new blob if a LATER store stage throws (so a
    /// half-stored item never leaves an orphan); the caller reclaims on a persist
    /// failure or a dedup-discard, using the returned `createdBlob`.
    private func storeBytesBlobFirst(
        _ byteSource: ByteSource, clock: ContinuousClock
    ) async throws -> StoredBytes {
        // 1. Bytes: in-memory as-is; a file URL is read now (a read failure —
        //    missing/unreadable file — maps to `.unreadableSource`).
        let bytes: Data
        switch byteSource {
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
        let afterMetadata = clock.now

        // Set only when THIS call created the blob; reclaimed here if a later
        // store stage throws, and returned so the caller can reclaim it too (G2).
        var createdBlob: (hash: String, fileExtension: String)? = nil
        do {
            // 4. Blob-first (A2) + hash-first short-circuit (P14). Store the blob
            //    only if not already present; an existing blob is complete
            //    (MediaStore atomicity), so this is free dedup.
            let blobExisted = store.hasBlob(hash: hash, fileExtension: meta.fileExtension)
            if !blobExisted {
                do {
                    try store.storeBlob(bytes, hash: hash, fileExtension: meta.fileExtension)
                    createdBlob = (hash, meta.fileExtension)
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
            let afterThumbnails = clock.now

            return StoredBytes(
                hash: hash, meta: meta, bytesCount: bytes.count,
                createdBlob: createdBlob, blobExisted: blobExisted,
                tiersGenerated: missingTiers.count,
                afterMetadata: afterMetadata, afterThumbnails: afterThumbnails)
        } catch {
            // A store stage failed after we wrote a brand-new blob — reclaim it so
            // MediaReaper isn't left with an orphan, then rethrow.
            if let created = createdBlob {
                _ = try? store.removeBlob(
                    hash: created.hash, fileExtension: created.fileExtension)
            }
            throw error
        }
    }

    /// Persist a byte-backed item — the original blob-first (A2) + P14 pipeline.
    private func ingestBytes(
        _ byteSource: ByteSource, input: IngestInput
    ) async -> IngestOutcome {
        // Phase 8 (16A): monotonic marks around each stage — negligible when the
        // timing sink is nil, and the signal that reveals a thumbnail stall (P16).
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let stored = try await storeBytesBlobFirst(byteSource, clock: clock)

            // 5. Persist in ONE transaction (P15). Only now — the blob is durable
            //    (A2), so the row can never reference a missing blob.
            let draft = AssetDraft(
                kind: stored.meta.kind,
                blobHash: stored.hash,
                mimeType: stored.meta.mimeType,
                width: stored.meta.width,
                height: stored.meta.height,
                duration: stored.meta.duration,
                fileSize: stored.bytesCount,
                downloadState: .downloaded)
            do {
                let result = try await services.ingest(
                    draft, from: input.provenance,
                    into: input.collectionID, placement: input.placement)
                let finished = clock.now

                // Emit the phase timing (16A) — reveals a thumbnail stall (P16 trigger).
                timing?(IngestTiming(
                    hash: stored.hash,
                    blobExisted: stored.blobExisted,
                    tiersGenerated: stored.tiersGenerated,
                    metadata: started.duration(to: stored.afterMetadata),
                    thumbnails: stored.afterMetadata.duration(to: stored.afterThumbnails),
                    persist: stored.afterThumbnails.duration(to: finished),
                    total: started.duration(to: finished)))

                // 6. Success — the asset (new or deduped) with the dedup flag.
                return .ingested(asset: result.asset, deduplicated: result.wasDeduplicated)
            } catch {
                // G2: persist failed after a brand-new blob was written — reclaim it.
                if let created = stored.createdBlob {
                    _ = try? store.removeBlob(
                        hash: created.hash, fileExtension: created.fileExtension)
                }
                throw error
            }
        } catch {
            return .failed(IngestError(mapping: error))
        }
    }

    /// Persist a MEDIA-LESS item that carries a card image (003 · C3, Option 3):
    /// run the shared blob-first store for the picture, then persist via
    /// `ingestContent(_:blob:)` so the asset keeps its `tweet` content identity
    /// AND renders its picture. Because dedup is by tweet-id (not bytes), a card
    /// image the funnel discards on dedup is reclaimed here — it would otherwise
    /// be an orphan the byte path never produces (there dedup implies the blob
    /// already existed).
    private func ingestContentWithBytes(
        _ draft: AssetContentDraft, _ byteSource: ByteSource, input: IngestInput
    ) async -> IngestOutcome {
        let clock = ContinuousClock()
        do {
            let stored = try await storeBytesBlobFirst(byteSource, clock: clock)
            let blob = ContentBlobFacts(
                blobHash: stored.hash, mimeType: stored.meta.mimeType,
                width: stored.meta.width, height: stored.meta.height,
                fileSize: stored.bytesCount)
            do {
                let result = try await services.ingestContent(
                    draft, blob: blob, from: input.provenance,
                    into: input.collectionID, placement: input.placement)
                // If the funnel deduped to an asset that does NOT reference our
                // freshly-stored blob, our card image is unreferenced — reclaim it
                // (compared case-insensitively; the on-disk key is `created.hash`).
                if let created = stored.createdBlob,
                   result.asset.blobHash?.lowercased() != created.hash.lowercased() {
                    _ = try? store.removeBlob(
                        hash: created.hash, fileExtension: created.fileExtension)
                }
                return .ingested(asset: result.asset, deduplicated: result.wasDeduplicated)
            } catch {
                // G2: persist failed after a brand-new blob was written — reclaim it.
                if let created = stored.createdBlob {
                    _ = try? store.removeBlob(
                        hash: created.hash, fileExtension: created.fileExtension)
                }
                throw error
            }
        } catch {
            return .failed(IngestError(mapping: error))
        }
    }
}
