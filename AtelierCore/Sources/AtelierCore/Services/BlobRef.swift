// AtelierCore — the blob descriptor that crosses the Core → Ingestion seam.
//
// Core owns `asset` rows but cannot touch files: `MediaStore` lives a layer up
// in AtelierIngestion, and path derivation (shard + extension) stays out of
// Core deliberately. So any Core read that has to name blobs ON DISK reports
// them as these GRDB-free descriptors, carrying the mime type the caller needs
// to round-trip the store-time file extension.
//
// Two directions use it, and the guarantee lives in the API that returns it,
// not in this type:
//   • `deleteAssets` → the blobs that just became UNREACHABLE (reclaimable).
//   • `referencedBlobs` → the blobs an asset still references (the keep set,
//     and the copy set for an off-device backup, 008 H5).
// One descriptor, because "a blob hash plus the mime that yields its file
// extension" is one concept; naming it twice would be two structs that must be
// kept identical forever.

import Foundation

/// A stored blob, named the way the filesystem addresses it.
///
/// `blobHash` is the content hash the blob + thumbnail files are addressed by;
/// `mimeType` lets the caller derive the blob's stored file extension (via
/// `ImageMetadata.fileExtension(forMIMEType:)` — thumbnails are always JPEG
/// regardless).
///
/// Whether a given `BlobRef` is safe to DELETE depends entirely on which call
/// produced it — see the returning method's contract. `deleteAssets` is
/// dedup-safe by construction: it only emits a hash whose asset count reached
/// zero inside the delete transaction, so a blob still shared by another asset
/// is never reported.
public struct BlobRef: Sendable, Equatable, Hashable {
    /// The content hash the blob + thumbnails are addressed by.
    public let blobHash: String
    /// The asset's MIME type — used to round-trip the blob's stored file
    /// extension (thumbnails are always JPEG regardless).
    public let mimeType: String

    public init(blobHash: String, mimeType: String) {
        self.blobHash = blobHash
        self.mimeType = mimeType
    }
}
