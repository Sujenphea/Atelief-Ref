// AtelierIngestion — which bytes an analysis pass actually looks at (012)
//
// One question, asked identically by every pass that runs a model over an asset:
// given this asset, what image do I hand the model? For an image it is the blob.
// For a VIDEO it is the poster frame — and that distinction is the reason videos
// have OCR, colors and suggested tags at all.
//
// **The poster is free.** It is rendered at ingest (`ThumbnailGenerator`
// .makeVideoPoster) and has been on disk as a JPEG tier ever since, which is what
// the grid and the detail placeholder already draw. So "analyze the poster frame"
// costs a thumbnail read, not the frame-sampling pipeline 012 priced it at when it
// deferred video analysis to v2. That deferral is what left a video's Colors
// section permanently empty and put every video out of reach of the ✦ chips.
//
// The tier is `.large` deliberately: it is the biggest poster on disk, and OCR —
// the analyzer's most resolution-hungry consumer — is the one that suffers first
// from a small source. The analyzer downsamples from whatever it gets.
//
// Shared by ``AnalysisBackfill`` and ``SuggestionBackfill`` so the two can never
// disagree about what a video looks like. If they did, an asset could be OCR'd
// from its poster and classified from a failed movie decode, and only the second
// would look broken.

import AtelierCore
import Foundation

/// Resolves the bytes an analysis pass should read for an asset (012).
enum AnalysisSource {
    /// Decodable image bytes for `asset`: its blob for an image, its poster JPEG
    /// for a video.
    ///
    /// - Throws: ``AnalysisSourceError/noImageBytes`` when the asset carries no
    ///   blob at all (a media-less kind, or a row raced by a delete — the
    ///   candidate queries exclude both, so this is a defensive guard), or
    ///   whatever ``MediaStore`` raises when the file is missing. A video whose
    ///   poster tier was never written (an old ingest, a reaped thumbnail) fails
    ///   HERE rather than by handing an `.mp4` to ImageIO — a typed miss the batch
    ///   counts and moves past, instead of a decode error that says nothing about
    ///   which file was wrong.
    static func imageData(for asset: Asset, in store: MediaStore) throws -> Data {
        guard let hash = asset.blobHash else {
            throw AnalysisSourceError.noImageBytes(asset.id)
        }
        if asset.kind == .video {
            return try store.readThumbnail(
                hash: hash, size: ThumbnailTier.large.rawValue, fileExtension: "jpg")
        }
        guard let mime = asset.mimeType else {
            throw AnalysisSourceError.noImageBytes(asset.id)
        }
        return try store.readBlob(
            hash: hash, fileExtension: ImageMetadata.fileExtension(forMIMEType: mime))
    }
}

/// An asset a pass cannot read image bytes for. Caught and counted by the batch
/// loops, never fatal.
enum AnalysisSourceError: Error, Equatable {
    case noImageBytes(UUID)
}
