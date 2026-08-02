// AtelierCore — who references a blob (016 · A, the largest-items list).
//
// `BlobRef` names a blob so a file layer can FIND it. This names a blob so a
// PERSON can recognise it — the item's display name, its kind, where it came
// from, and every asset row that would have to go for the file to be reclaimed.
//
// It is per-BLOB rather than per-asset on purpose. Dedup means one file can
// back several assets, and a largest-items list is a list of files: ranking
// assets would show one 240 MB video three times and imply 720 MB that isn't
// there. The corollary is that deleting to reclaim the file means deleting all
// of `assetIDs`, which is why they travel with the row instead of being fetched
// later — a delete that frees nothing because a sibling asset still holds the
// blob is exactly the confusing outcome this avoids.

import Foundation

/// One distinct blob, its identity for display, and the assets that reference
/// it. GRDB-free, like every value that crosses out of Core.
public struct BlobUsage: Sendable, Equatable, Hashable {
    /// The content hash the blob + thumbnails are addressed by.
    public let blobHash: String
    /// The MIME type that round-trips the blob's stored file extension. `""`
    /// when unknown, matching ``BlobRef`` and `MediaStore`'s dotless path.
    public let mimeType: String
    /// The medium, for an icon and a label. Byte-backed by construction.
    public let kind: AssetKind
    /// Where the referencing asset came from.
    public let platform: Platform
    /// The best human label available — the user's asset name, else the source
    /// title. `nil` when the item has neither and the UI must fall back.
    public let displayName: String?
    /// Every asset referencing this blob, sorted for determinism. Deleting all
    /// of them is what reclaims the file.
    public let assetIDs: [UUID]

    /// How many assets share this one file — `> 1` means deleting any single
    /// one frees nothing.
    public var assetCount: Int { assetIDs.count }

    public init(
        blobHash: String,
        mimeType: String,
        kind: AssetKind,
        platform: Platform,
        displayName: String?,
        assetIDs: [UUID]
    ) {
        self.blobHash = blobHash
        self.mimeType = mimeType
        self.kind = kind
        self.platform = platform
        self.displayName = displayName
        self.assetIDs = assetIDs
    }
}
