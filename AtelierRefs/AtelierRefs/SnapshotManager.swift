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
    /// Pre-destructive snapshots younger than this are exempt from pruning —
    /// "what did that delete take?" is often discovered weeks later, and with
    /// dailies on, a pre-destructive snapshot would otherwise roll off the
    /// `recent` window within a week. Snapshots are KB–MB, so the floor is
    /// effectively free. Older than the floor, they rejoin the rolling pool.
    var preDestructiveFloor: TimeInterval = 30 * 86_400

    /// The subset of `snapshots` to DELETE, judged at `now`. Pre-migration
    /// snapshots are never returned (kept forever); pre-destructive snapshots
    /// inside `preDestructiveFloor` are exempt too. Among the rest ("rolling"),
    /// the `recent` newest are kept, then the newest snapshot in each of the
    /// next `weeklyWeeks` distinct ISO weeks; everything older / extra is
    /// pruned.
    func prunable(
        _ snapshots: [SnapshotFile],
        now: Date,
        calendar: Calendar = Calendar(identifier: .iso8601)
    ) -> [SnapshotFile] {
        let rolling = snapshots
            .filter { $0.reason != .preMigration }
            .filter {
                !($0.reason == .preDestructive
                    && now.timeIntervalSince($0.date) < preDestructiveFloor)
            }
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
    /// The clock — injectable so staleness boundaries, the pre-destructive
    /// freshness gate, and the retention age floor are testable.
    private let now: () -> Date

    init(services: AppServices, directory: URL, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.directory = directory
        self.now = now
    }

    /// Every parsed snapshot on disk, newest first.
    func list() -> [SnapshotFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { SnapshotFile(url: $0) }.sorted { $0.date > $1.date }
    }

    /// The on-disk size of `snapshot` in bytes. Snapshots are normalized to a
    /// single self-contained file; the sidecar sum is the compatibility net for
    /// pre-normalization snapshots. `0` if the file is gone.
    func byteSize(of snapshot: SnapshotFile) -> Int64 {
        SQLiteFileSet(base: snapshot.url).totalByteSize()
    }

    /// Delete one snapshot (+ any sidecars) on the user's explicit request.
    /// Unlike `prune`, this honours a manual delete of ANY snapshot — including
    /// pre-migration, which auto-retention keeps forever. Best-effort.
    func delete(_ snapshot: SnapshotFile) {
        SQLiteFileSet(base: snapshot.url).remove()
    }

    /// Take a snapshot for `reason` now, then prune per the retention policy.
    /// Returns the new snapshot's URL.
    @discardableResult
    func snapshot(reason: SnapshotReason) async throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = SnapshotFile.makeURL(in: directory, reason: reason, date: now())
        try await services.snapshot(to: url)
        prune()
        return url
    }

    /// Daily-on-launch: snapshot if there's no daily snapshot newer than
    /// `maxAge`. Best-effort — failures are swallowed so a backup hiccup never
    /// blocks or disrupts launch.
    func snapshotIfStale(maxAge: TimeInterval = 24 * 60 * 60) async {
        let newestDaily = list().first { $0.reason == .daily }
        if let newestDaily, now().timeIntervalSince(newestDaily.date) < maxAge {
            return
        }
        _ = try? await snapshot(reason: .daily)
    }

    /// The pre-destructive net, freshness-gated: take a snapshot unless ANY
    /// snapshot is newer than `maxAge`. A pre-existing snapshot by definition
    /// predates the destruction about to happen, so it IS the net — skipping
    /// avoids a full-DB `VACUUM INTO` on every delete in a triage session (and
    /// the retention churn ten pre-destructive files would cause). Returns the
    /// new snapshot's URL, or `nil` when a fresh one already stood guard.
    @discardableResult
    func snapshotBeforeDestruction(maxAge: TimeInterval = 10 * 60) async throws -> URL? {
        if let newest = list().first, now().timeIntervalSince(newest.date) < maxAge {
            return nil
        }
        return try await snapshot(reason: .preDestructive)
    }

    /// Consume Core's "pre-migration snapshot failed" marker: `true` (once) if
    /// the last open migrated the library WITHOUT its safety copy — the caller
    /// surfaces that loudly. The marker is removed so the warning fires once.
    func consumePreMigrationSnapshotFailure() -> Bool {
        let marker = directory.appendingPathComponent(".pre-migration-snapshot-failed")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        try? FileManager.default.removeItem(at: marker)
        return true
    }

    /// Delete the snapshots retention rolls off (+ any sidecars a
    /// pre-normalization snapshot carried). Best-effort.
    func prune() {
        for snap in retention.prunable(list(), now: now()) {
            SQLiteFileSet(base: snap.url).remove()
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
        // A file that can't even be opened is unhealthy by definition — fold
        // open-failures into the one typed refusal instead of leaking a raw
        // database error to the sheet.
        guard (try? AppServices.isHealthy(databaseFileAt: snapshot.url)) == true else {
            throw SnapshotError.unhealthySnapshot
        }
        try snapshot.url.lastPathComponent.write(
            to: restoreMarker, atomically: true, encoding: .utf8)
    }

    /// At bootstrap, BEFORE `AppServices` opens: if a restore is staged, install
    /// the named snapshot as the live database. The live DB (+ sidecars) is moved
    /// aside as `library.corrupt-<epoch>.sqlite` — **never destroyed**. Safe: a
    /// bad/missing marker is cleared, and a failure rolls the live DB back so the
    /// app still opens.
    ///
    /// Install order is deliberate (the anti-truncation invariant): the snapshot
    /// is first COPIED to a staging name next to the live DB — the live file set
    /// is untouched until that copy has fully succeeded — then the live set moves
    /// aside and the staged copy RENAMES into place (same-volume, atomic per
    /// file). A partial copy can therefore never sit at the live path, and the
    /// catch path removes staging litter BEFORE deciding whether to roll back,
    /// so a leftover fragment can't mask a missing live DB.
    static func applyPendingRestore(snapshotsDir: URL, livePath: URL) {
        let fm = FileManager.default
        let marker = snapshotsDir.appendingPathComponent(".pending-restore")
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return }
        defer { try? fm.removeItem(at: marker) }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = snapshotsDir.appendingPathComponent(name)
        guard !name.isEmpty, fm.fileExists(atPath: snapshot.path),
              (try? AppServices.isHealthy(databaseFileAt: snapshot)) == true
        else { return }

        let stamp = String(Int(Date().timeIntervalSince1970))
        let dir = livePath.deletingLastPathComponent()
        let live = SQLiteFileSet(base: livePath)
        let aside = SQLiteFileSet(
            base: dir.appendingPathComponent("library.corrupt-\(stamp).sqlite"))
        let staging = SQLiteFileSet(
            base: dir.appendingPathComponent(".restore-staging-\(stamp).sqlite"))
        do {
            try SQLiteFileSet(base: snapshot).copy(to: staging)
            if live.exists { try live.move(to: aside) }
            try staging.move(to: live)
            // Tell the next bootstrap a restore just landed (008 review, 3A): it
            // reconciles blobs against the restored DB and REPORTS instead of
            // silently reaping media the snapshot doesn't know about.
            try? "".write(
                to: snapshotsDir.appendingPathComponent(".just-restored"),
                atomically: true, encoding: .utf8)
        } catch {
            staging.remove()
            // Roll the live DB back if we moved it aside but couldn't install.
            if !live.exists, aside.exists { try? aside.move(to: live) }
        }
    }

    /// Consume the "a restore just landed" marker: `true` exactly once after a
    /// successful ``applyPendingRestore``. The caller runs the post-restore blob
    /// reconcile (report, don't reap) in place of that launch's orphan GC.
    func consumeJustRestored() -> Bool {
        let marker = directory.appendingPathComponent(".just-restored")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        try? FileManager.default.removeItem(at: marker)
        return true
    }
}

/// A snapshot-manager failure surfaced to the user.
enum SnapshotError: Error, Equatable {
    /// The chosen snapshot failed its integrity check and won't be restored.
    case unhealthySnapshot
}

/// Pure set math for the post-restore blob reconcile (008 review, 3A) — the two
/// directions restoring an older snapshot can silently diverge from the disk.
struct PostRestoreBlobReport: Equatable {
    /// Blobs the restored DB references that are no longer on disk (orphaned and
    /// trashed sometime AFTER the snapshot was taken) — those items render
    /// without media, and recovery is the user's Trash, not ours (sandbox).
    let missingReferenced: Int
    /// Blobs on disk the restored DB doesn't reference (captured after the
    /// snapshot) — kept and reported this launch instead of silently trashed;
    /// the NEXT launch's orphan GC reclaims whatever the user doesn't rescue.
    let keptUnreferenced: Int

    init(referenced: Set<String>, onDisk: Set<String>) {
        missingReferenced = referenced.subtracting(onDisk).count
        keptUnreferenced = onDisk.subtracting(referenced).count
    }

    var isClean: Bool { missingReferenced == 0 && keptUnreferenced == 0 }
}
