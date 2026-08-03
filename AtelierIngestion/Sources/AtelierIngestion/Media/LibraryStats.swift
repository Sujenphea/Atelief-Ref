// AtelierIngestion — joining the DB's blob rows to the disk's blob sizes (016 · A).
//
// The largest-items list is the one place the two halves of "library stats"
// meet: Core knows WHICH blobs exist and who references them
// (`AppServices.blobUsage()`), the filesystem knows how BIG they are
// (`LibraryStorageScanner`). Core can't touch files and the scanner can't read
// SQL, so the join lives here — in the layer that already owns both.
//
// It is a pure function over two values. No IO, no `stat`, no query: given the
// same rows and the same sizes it returns the same list, which is what makes
// "exact top-N ordering" a thing a test can assert rather than observe.

import AtelierCore
import Foundation

/// One row of the largest-items list: a blob, its measured size, and everything
/// needed to reveal, open, or reclaim it.
public struct LargestItem: Sendable, Equatable, Identifiable {
    /// Who references the blob and what to call it.
    public let usage: BlobUsage
    /// The blob file's measured size on disk.
    public let byteSize: Int64

    /// Identified by the blob, because the list is one row per FILE.
    public var id: String { usage.blobHash }

    public var blobHash: String { usage.blobHash }
    public var mimeType: String { usage.mimeType }
    public var assetIDs: [UUID] { usage.assetIDs }

    public init(usage: BlobUsage, byteSize: Int64) {
        self.usage = usage
        self.byteSize = byteSize
    }
}

/// Pure aggregation over library stats. A namespace of `static` functions — no
/// state, no IO.
public enum LibraryStats {

    /// The `limit` largest blobs, biggest first.
    ///
    /// A blob with no entry in `sizes` has no file on disk — a failed download,
    /// or bytes already trashed — so it occupies nothing and is EXCLUDED rather
    /// than ranked as zero. A list of the biggest things in the library that
    /// includes things which aren't there would be worse than short.
    ///
    /// Ties break on `blobHash` ascending. Equal sizes are common (two copies of
    /// the same 4 KB avatar), and without a tie-break the order would depend on
    /// the sort's stability, so a refresh that measured nothing new could still
    /// reshuffle the rows.
    public static func largestItems(
        blobs: [BlobUsage], sizes: [String: Int64], limit: Int
    ) -> [LargestItem] {
        guard limit > 0 else { return [] }
        var sized: [LargestItem] = []
        for usage in blobs {
            guard let bytes = sizes[usage.blobHash] else { continue }
            sized.append(LargestItem(usage: usage, byteSize: bytes))
        }
        sized.sort { left, right in
            if left.byteSize != right.byteSize { return left.byteSize > right.byteSize }
            return left.blobHash < right.blobHash
        }
        return Array(sized.prefix(limit))
    }

    /// Counts in a fixed, declaration-order sequence, dropping the empties.
    ///
    /// The map from Core is unordered, and a stats pane whose rows jump around
    /// between refreshes is unreadable. `CaseIterable` order is the enum's own
    /// order, which is stable across builds by construction.
    ///
    /// A zero is DROPPED rather than rendered: a library that has never captured
    /// a video should not have a "Videos 0" row explaining what it doesn't have.
    public static func ordered<Key>(
        _ counts: [Key: Int]
    ) -> [LibraryCount<Key>] where Key: CaseIterable & Hashable & Sendable {
        Key.allCases.compactMap { key in
            guard let count = counts[key], count > 0 else { return nil }
            return LibraryCount(key: key, count: count)
        }
    }
}

/// One count row — a struct rather than a tuple so it is `Identifiable` and a
/// SwiftUI `ForEach` can key off it directly.
public struct LibraryCount<Key: Hashable & Sendable>: Sendable, Equatable, Identifiable {
    public let key: Key
    public let count: Int

    public var id: Key { key }

    public init(key: Key, count: Int) {
        self.key = key
        self.count = count
    }
}
