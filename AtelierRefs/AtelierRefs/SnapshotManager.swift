//
//  SnapshotManager.swift
//  AtelierRefs
//
//  The app-side orchestration for library snapshots (008 H3): taking snapshots
//  (via Core's `AppServices.snapshot(to:)`), enforcing retention, and the
//  daily-on-launch check. The naming + the pre-migration snapshot live in Core;
//  everything here is GRDB-free orchestration.
//
//  Retention (confirmed policy): keep the 7 newest rolling snapshots, then the
//  newest in each of up to 4 further weeks; pre-migration snapshots are never
//  pruned. `SnapshotRetention` is a pure function so it's unit-tested directly.
//

import AtelierCore
import Foundation

/// Pure retention policy: which snapshots to delete.
struct SnapshotRetention {
    /// Keep this many of the newest rolling (non-pre-migration) snapshots.
    var recent = 7
    /// Then keep the newest snapshot in each of up to this many further weeks.
    var weeklyWeeks = 4

    /// The subset of `snapshots` to DELETE. Pre-migration snapshots are never
    /// returned (kept forever). Among the rest ("rolling": daily / manual /
    /// pre-destructive), the `recent` newest are kept, then the newest snapshot
    /// in each of the next `weeklyWeeks` distinct ISO weeks; everything older /
    /// extra is pruned.
    func prunable(
        _ snapshots: [SnapshotFile],
        calendar: Calendar = Calendar(identifier: .iso8601)
    ) -> [SnapshotFile] {
        let rolling = snapshots
            .filter { $0.reason != .preMigration }
            .sorted { $0.date > $1.date }
        let older = rolling.dropFirst(recent)
        var keptWeeks = Set<DateComponents>()
        var delete: [SnapshotFile] = []
        for snap in older { // newest-first, so the first seen per week is kept
            let week = calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: snap.date)
            if keptWeeks.count < weeklyWeeks, !keptWeeks.contains(week) {
                keptWeeks.insert(week)
            } else {
                delete.append(snap)
            }
        }
        return delete
    }
}

@MainActor
final class SnapshotManager {
    private let services: AppServices
    /// The `snapshots/` directory (`LibraryLayout.snapshots`).
    let directory: URL
    private let retention = SnapshotRetention()

    init(services: AppServices, directory: URL) {
        self.services = services
        self.directory = directory
    }

    /// Every parsed snapshot on disk, newest first.
    func list() -> [SnapshotFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { SnapshotFile(url: $0) }.sorted { $0.date > $1.date }
    }

    /// Take a snapshot for `reason` now, then prune per the retention policy.
    /// Returns the new snapshot's URL.
    @discardableResult
    func snapshot(reason: SnapshotReason) async throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = SnapshotFile.makeURL(in: directory, reason: reason, date: Date())
        try await services.snapshot(to: url)
        prune()
        return url
    }

    /// Daily-on-launch: snapshot if there's no daily snapshot newer than
    /// `maxAge`. Best-effort — failures are swallowed so a backup hiccup never
    /// blocks or disrupts launch.
    func snapshotIfStale(maxAge: TimeInterval = 24 * 60 * 60) async {
        let newestDaily = list().first { $0.reason == .daily }
        if let newestDaily, Date().timeIntervalSince(newestDaily.date) < maxAge {
            return
        }
        try? await snapshot(reason: .daily)
    }

    /// Delete the snapshots retention rolls off (+ any `-wal`/`-shm` sidecars a
    /// pre-migration snapshot carried). Best-effort.
    func prune() {
        for snap in retention.prunable(list()) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: snap.url.path + suffix)
            }
        }
    }

    // MARK: - Restore (008 H3)

    /// The marker file that requests a restore on the next launch.
    private var restoreMarker: URL { directory.appendingPathComponent(".pending-restore") }

    /// Whether a restore is staged for the next launch.
    func hasPendingRestore() -> Bool {
        FileManager.default.fileExists(atPath: restoreMarker.path)
    }

    /// Validate `snapshot` and stage it to be restored on the next launch (writes
    /// a marker naming it). Throws `.unhealthySnapshot` if it fails integrity. The
    /// actual file swap happens at bootstrap, before the pool opens — the only
    /// safe time to move the live database (no writer yet), which is why restore
    /// is deferred to relaunch rather than torn down live.
    func stageRestore(_ snapshot: SnapshotFile) throws {
        guard try AppServices.isHealthy(databaseFileAt: snapshot.url) else {
            throw SnapshotError.unhealthySnapshot
        }
        try snapshot.url.lastPathComponent.write(
            to: restoreMarker, atomically: true, encoding: .utf8)
    }

    /// At bootstrap, BEFORE `AppServices` opens: if a restore is staged, install
    /// the named snapshot as the live database. The live DB (+ sidecars) is moved
    /// aside as `library.corrupt-<epoch>.sqlite` — **never destroyed** — then the
    /// snapshot (+ any sidecars) is copied into place. Best-effort and safe: a
    /// bad/missing marker is cleared, and a failure mid-swap rolls the live DB
    /// back so the app still opens.
    static func applyPendingRestore(snapshotsDir: URL, livePath: URL) {
        let fm = FileManager.default
        let marker = snapshotsDir.appendingPathComponent(".pending-restore")
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = snapshotsDir.appendingPathComponent(name)
        guard !name.isEmpty, fm.fileExists(atPath: snapshot.path),
              (try? AppServices.isHealthy(databaseFileAt: snapshot)) == true
        else {
            try? fm.removeItem(at: marker)
            return
        }

        let stamp = String(Int(Date().timeIntervalSince1970))
        let aside = livePath.deletingLastPathComponent()
            .appendingPathComponent("library.corrupt-\(stamp).sqlite")
        do {
            if fm.fileExists(atPath: livePath.path) {
                try fm.moveItem(at: livePath, to: aside)
            }
            for s in ["-wal", "-shm"] {
                if fm.fileExists(atPath: livePath.path + s) {
                    try? fm.moveItem(atPath: livePath.path + s, toPath: aside.path + s)
                }
            }
            try fm.copyItem(at: snapshot, to: livePath)
            for s in ["-wal", "-shm"] { // a pre-migration snapshot may carry these
                if fm.fileExists(atPath: snapshot.path + s) {
                    try? fm.copyItem(atPath: snapshot.path + s, toPath: livePath.path + s)
                }
            }
            try? fm.removeItem(at: marker)
        } catch {
            // Roll the live DB back if we moved it aside but couldn't install.
            if !fm.fileExists(atPath: livePath.path), fm.fileExists(atPath: aside.path) {
                try? fm.moveItem(at: aside, to: livePath)
            }
            try? fm.removeItem(at: marker)
        }
    }
}

/// A snapshot-manager failure surfaced to the user.
enum SnapshotError: Error, Equatable {
    /// The chosen snapshot failed its integrity check and won't be restored.
    case unhealthySnapshot
}
