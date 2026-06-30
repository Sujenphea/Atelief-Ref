// AtelierCore
//
// Phase 1 metadata-store skeleton for ref-atelier. This file is intentionally a
// placeholder for the package skeleton (Checkpoint 1): it proves the package
// builds and that GRDB links and is usable. The real schema, record types, and
// store API land in later checkpoints.

import GRDB

/// Marker namespace for the local metadata store. Replaced by real surface area
/// as the checkpoints land.
public enum AtelierCore {
    /// The on-disk filename for the library's SQLite database.
    public static let databaseFileName = "library.sqlite"

    /// Opens an in-memory SQLite database via GRDB and reads back the schema
    /// version, forcing the linker to resolve GRDB. Returns the `user_version`
    /// pragma value of a fresh database (0).
    ///
    /// This exists only to exercise GRDB end-to-end during the skeleton
    /// checkpoint; it is replaced by the real store once the schema lands.
    static func probeUserVersion() throws -> Int {
        let queue = try DatabaseQueue()
        return try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
        }
    }
}
