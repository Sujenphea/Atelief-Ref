// AtelierIngestion — where an off-device backup puts things (008 · H5)
//
// Pure path math over the user-chosen target folder, the mirror image of
// `LibraryLayout`. It creates nothing; the copier creates directories on demand,
// exactly as `MediaStore` does locally.
//
//   <target>/<library-id>/
//     blobs/ab/cd/<hash>.<ext>   ← the SAME shard scheme as the live library
//     cache/                     ← staging for the copier's atomic renames
//     library.sqlite             ← a VACUUM INTO copy, self-contained
//     library.sqlite.new         ← transient: this run's copy, before it replaces
//     backup-manifest.json       ← what this destination holds, and from what
//
// Reusing `LibraryLayout` for the blob side is the point. `MediaStore(root:)`
// over the destination gives sharding, existence checks, and staged atomic
// installs for free, so there is exactly one implementation of "where does the
// blob for this hash go" in the codebase — and the diff that drives an
// incremental backup is sound only if both sides agree on it exactly.
//
// Deliberately absent: `thumbnails/` and `snapshots/`. Thumbnails are
// regenerable (and already excluded from local backups); snapshots are recovery
// artifacts of the SOURCE machine, and copying them multiplies the footprint
// without adding any recovery the destination's own database copy doesn't give.

import Foundation

/// The on-disk layout of one library's off-device backup, inside a target
/// folder that may hold several.
public struct BackupLayout: Sendable {
    /// The target folder the user chose — the parent of every library's backup.
    public let target: URL

    /// The library this layout backs up, by ``LibraryIdentity``.
    public let libraryID: String

    /// Build the layout for `libraryID` inside `target`. Pure path math.
    public init(target: URL, libraryID: String) {
        self.target = target
        self.libraryID = libraryID
    }

    /// This library's backup root: `<target>/<library-id>/`.
    public var root: URL {
        target.appendingPathComponent(libraryID, isDirectory: true)
    }

    /// The blob-side layout, so `MediaStore` does the destination path math.
    public var library: LibraryLayout {
        LibraryLayout(root: root)
    }

    /// A store over the destination — same sharding, same atomic installs.
    public var store: MediaStore {
        MediaStore(layout: library)
    }

    /// The database copy readers should trust.
    public var database: URL {
        root.appendingPathComponent("library.sqlite", isDirectory: false)
    }

    /// Where a run writes its database copy BEFORE it replaces ``database``.
    ///
    /// `AppServices.snapshot(to:)` refuses to overwrite, and more importantly a
    /// run that fails halfway must not have already destroyed the previous good
    /// copy — so each run writes here, verifies, and only then renames over.
    public var incomingDatabase: URL {
        root.appendingPathComponent("library.sqlite.new", isDirectory: false)
    }

    /// What this destination holds, and which app and schema wrote it.
    public var manifest: URL {
        root.appendingPathComponent("backup-manifest.json", isDirectory: false)
    }
}
