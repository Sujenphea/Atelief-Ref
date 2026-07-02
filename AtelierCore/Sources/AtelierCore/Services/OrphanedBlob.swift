// AtelierCore — the reclaimable-blob descriptor returned by a delete.
//
// `AppServices` (AtelierCore) deletes `asset` rows but cannot touch files —
// `MediaStore` lives a layer up in AtelierIngestion. So `deleteAssets` reports
// which blobs became orphans (their LAST referencing asset was removed) as these
// GRDB-free descriptors, and the caller (which owns a `MediaStore`) reclaims the
// on-disk blob + thumbnail files. Path derivation stays out of Core: the mime
// type is carried so the caller can round-trip the store-time file extension.

import Foundation

/// A blob whose last referencing asset was deleted, so its on-disk files
/// (the blob and its thumbnail tiers) are now reclaimable.
///
/// `blobHash` is the content hash the files are addressed by; `mimeType` lets
/// the caller derive the blob's stored file extension. Dedup-safe by
/// construction: `deleteAssets` only emits a hash whose asset count reached zero
/// inside the delete transaction, so a blob still shared by another asset is
/// never reported.
public struct OrphanedBlob: Sendable, Equatable, Hashable {
    /// The content hash the blob + thumbnails are addressed by.
    public let blobHash: String
    /// The deleted asset's MIME type — used to round-trip the blob's stored
    /// file extension (thumbnails are always JPEG regardless).
    public let mimeType: String

    public init(blobHash: String, mimeType: String) {
        self.blobHash = blobHash
        self.mimeType = mimeType
    }
}
