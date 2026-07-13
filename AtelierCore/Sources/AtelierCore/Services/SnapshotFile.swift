// AtelierCore — snapshot filename convention (008 H3)
//
// A shared value type naming library snapshots `<reason>-<yyyyMMdd-HHmmss>-<id>.sqlite`.
// The reason prefix lets the app's retention policy treat pre-migration snapshots
// as sacrosanct while rolling the rest. Core takes the pre-migration snapshot (in
// LibraryDatabase.init); the app takes daily / manual / pre-destructive and owns
// retention — both agree on the name through this one type. No orchestration
// lives here (that stays in the app); this is pure naming.

import Foundation

/// Why a library snapshot was taken. The raw value is the filename prefix.
public enum SnapshotReason: String, Sendable, CaseIterable {
    /// The optional daily-on-launch auto-snapshot (rolling, prunable).
    case daily
    /// A user-invoked "Snapshot now" (rolling, prunable).
    case manual
    /// Taken automatically before a schema migration (NEVER auto-pruned).
    case preMigration = "pre-migration"
    /// Taken automatically before a bulk destructive delete (rolling, prunable).
    case preDestructive = "pre-destructive"
}

/// A parsed snapshot filename: its `reason` and capture `date`. The timestamp is
/// UTC and sorts lexically; a short random id avoids same-second collisions.
public struct SnapshotFile: Sendable, Equatable {
    public let url: URL
    public let reason: SnapshotReason
    public let date: Date

    /// Build a fresh snapshot URL for `reason` at `date` under `directory`.
    public static func makeURL(
        in directory: URL,
        reason: SnapshotReason,
        date: Date,
        id: String = String(UUID().uuidString.prefix(8)).lowercased()
    ) -> URL {
        let stamp = Self.formatter.string(from: date)
        return directory.appendingPathComponent("\(reason.rawValue)-\(stamp)-\(id).sqlite")
    }

    /// Parse a snapshot URL, or `nil` if the name isn't a recognized snapshot
    /// (`<reason>-<yyyyMMdd-HHmmss>-<id>.sqlite`).
    public init?(url: URL) {
        guard url.pathExtension == "sqlite" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        // Longest matching prefix first, so "pre-migration"/"pre-destructive"
        // win over any shorter accidental match.
        guard let reason = SnapshotReason.allCases
            .sorted(by: { $0.rawValue.count > $1.rawValue.count })
            .first(where: { name.hasPrefix($0.rawValue + "-") })
        else { return nil }
        let rest = name.dropFirst(reason.rawValue.count + 1)
        // The stamp is the fixed-width leading "yyyyMMdd-HHmmss" (15 chars).
        guard rest.count >= 15,
              let date = Self.formatter.date(from: String(rest.prefix(15)))
        else { return nil }
        self.url = url
        self.reason = reason
        self.date = date
    }

    /// UTC, POSIX, filesystem-safe (no colons). `yyyyMMdd-HHmmss`.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
