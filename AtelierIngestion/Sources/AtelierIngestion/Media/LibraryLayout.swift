// AtelierIngestion — the Library directory layout (chunk 2, decision C6 / 003 storage layout)
//
// Pure path math over a single root directory. It names the standard
// subdirectories the media store writes into — `blobs/` (content-addressed
// originals), `thumbnails/` (derived, regenerable), and `cache/` (transient,
// purgeable, and where atomic writes stage their temp files). It creates
// nothing on disk; directory creation is the media store's job, on demand.

import Foundation

/// The on-disk layout of a single Library directory (003 storage layout).
///
/// A value type wrapping the Library `root` and exposing the standard
/// subdirectories as computed `URL`s. It is pure path arithmetic: constructing
/// a `LibraryLayout` touches no filesystem and creates no directories.
///
/// `struct … Sendable` — the only stored property is a `URL` (itself
/// `Sendable`), so the layout crosses concurrency domains freely.
public struct LibraryLayout: Sendable {
    /// The Library root directory. All subdirectories are resolved beneath it.
    public let root: URL

    /// Wrap `root` as a Library layout. Pure path math — nothing is created.
    public init(root: URL) {
        self.root = root
    }

    /// Content-addressed original media, sharded by hash prefix (`blobs/ab/cd/…`).
    public var blobs: URL {
        root.appendingPathComponent("blobs", isDirectory: true)
    }

    /// Derived, regenerable thumbnails, sharded by hash prefix
    /// (`thumbnails/ab/cd/…`). Excluded from backups, purgeable.
    public var thumbnails: URL {
        root.appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// Transient scratch space, safe to purge. Atomic writes stage their temp
    /// files here so the move into `blobs`/`thumbnails` stays on the same volume.
    public var cache: URL {
        root.appendingPathComponent("cache", isDirectory: true)
    }
}
