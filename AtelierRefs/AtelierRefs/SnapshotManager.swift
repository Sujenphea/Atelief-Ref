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
}
