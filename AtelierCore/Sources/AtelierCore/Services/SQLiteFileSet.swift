// AtelierCore — a SQLite database file plus its `-wal`/`-shm` sidecars, moved,
// copied, sized, and removed as ONE unit (008).
//
// Every place that handles a database *file* (staging a pre-migration copy,
// promoting or pruning a snapshot, setting the live DB aside during restore)
// must treat the trio as inseparable — a base file without its WAL silently
// loses committed transactions. Before this type, that loop was hand-rolled at
// seven call sites with subtly different semantics (`try` vs `try?`,
// exists-checks vs not), which is exactly where sidecar bugs hid. Normalized
// snapshots (`LibraryDatabase.normalize`) have no sidecars, so most sets are a
// single file in practice; the sidecar handling is the compatibility net for
// pre-normalization snapshots and for the live database itself.

import Foundation

/// A database file set rooted at `base` (`…/x.sqlite` → `x.sqlite`,
/// `x.sqlite-wal`, `x.sqlite-shm`). Pure path math plus explicit filesystem
/// verbs; nothing is touched at construction time.
public struct SQLiteFileSet: Sendable {
    /// The main database file. Sidecar paths are derived by suffixing it.
    public let base: URL

    /// The sidecar suffixes SQLite may leave beside a database file.
    public static let sidecarSuffixes = ["-wal", "-shm"]

    public init(base: URL) {
        self.base = base
    }

    /// Whether the main database file exists (sidecars are optional by nature).
    public var exists: Bool {
        FileManager.default.fileExists(atPath: base.path)
    }

    /// Copy the set to `destination`: the base file MUST copy (throws
    /// otherwise), and every sidecar that exists must copy too — a set copy
    /// that silently drops a WAL is worse than one that fails loudly.
    public func copy(to destination: SQLiteFileSet) throws {
        let fm = FileManager.default
        try fm.copyItem(at: base, to: destination.base)
        for suffix in Self.sidecarSuffixes where fm.fileExists(atPath: base.path + suffix) {
            try fm.copyItem(
                atPath: base.path + suffix, toPath: destination.base.path + suffix)
        }
    }

    /// Move the set to `destination` — same strictness as ``copy(to:)``. The
    /// base file moves first, so on a same-volume rename the database itself
    /// commits atomically before any sidecar follows.
    public func move(to destination: SQLiteFileSet) throws {
        let fm = FileManager.default
        try fm.moveItem(at: base, to: destination.base)
        for suffix in Self.sidecarSuffixes where fm.fileExists(atPath: base.path + suffix) {
            try fm.moveItem(
                atPath: base.path + suffix, toPath: destination.base.path + suffix)
        }
    }

    /// Remove every member that exists. Best-effort by design — removal is
    /// always cleanup, and a leftover file is harmless disk, never corruption.
    public func remove() {
        let fm = FileManager.default
        try? fm.removeItem(at: base)
        for suffix in Self.sidecarSuffixes {
            try? fm.removeItem(atPath: base.path + suffix)
        }
    }

    /// The summed on-disk size of every member that exists; `0` if none do.
    public func totalByteSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for path in [base.path] + Self.sidecarSuffixes.map({ base.path + $0 }) {
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}
