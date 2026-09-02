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
import AtelierIngestion
import Foundation
import os

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

    // MARK: - Best-effort, but not silent (099 · 6A)

    /// Run `work`, returning `nil` and LOGGING when it throws.
    ///
    /// `nonisolated`, like the marker helpers below it: these are filesystem
    /// bookkeeping, and the launch sweep that reads them runs on a detached task.
    ///
    /// This file had twelve `try?`s, and every one of them was a deliberate
    /// best-effort: snapshot bookkeeping must never stop a launch, a delete or a
    /// restore. That decision is not in question — what was wrong is that a
    /// swallowed failure here produces symptoms nobody can trace back. A marker
    /// that will not delete makes a one-time warning fire on every launch forever.
    /// A `.just-restored` file that will not write makes the NEXT launch reap the
    /// media the restore was protecting. A rollback that fails leaves the app with
    /// no database at all. Each of those is a bug report that arrives as "it keeps
    /// doing this" with nothing in the log underneath it.
    ///
    /// `what` is a short phrase naming the attempt, in the sentence "snapshots:
    /// <what> failed: <error>". `.public` throughout: these name marker files and
    /// filesystem errors, never user content.
    @discardableResult
    nonisolated static func attempt<T>(_ what: String, _ work: () throws -> T) -> T? {
        do {
            return try work()
        } catch {
            AppLog.model.error(
                "snapshots: \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Every parsed snapshot on disk, newest first.
    func list() -> [SnapshotFile] {
        // A directory that does not exist yet is the ordinary first-launch state,
        // not a failure — only a directory that exists and will not READ is worth a
        // line, and that one means the snapshots sheet is about to show "none" for a
        // library that has them.
        let urls: [URL]
        if FileManager.default.fileExists(atPath: directory.path) {
            urls = Self.attempt("listing \(directory.lastPathComponent)/") {
                try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
            } ?? []
        } else {
            urls = []
        }
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
        do {
            _ = try await snapshot(reason: .daily)
        } catch {
            // Swallowed by design (the doc above), and now audible: a library whose
            // daily snapshot has been failing silently has no recovery point, and
            // the first anyone would learn of it is the day they need one.
            AppLog.model.error(
                "snapshots: the daily snapshot failed — this library has no fresh recovery point: \(String(describing: error), privacy: .public)")
        }
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
        // "Fires once" is the whole contract of this method, and it is the removal
        // that keeps it. A removal that fails turns a one-time warning into a
        // permanent one, which reads to the user as the app being broken.
        Self.attempt("clearing the pre-migration-failure marker") {
            try FileManager.default.removeItem(at: marker)
        }
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
        guard Self.attempt("integrity-checking \(snapshot.url.lastPathComponent)", {
            try AppServices.isHealthy(databaseFileAt: snapshot.url)
        }) == true else {
            // The sheet gets one typed refusal, deliberately (above). The reason
            // the file would not open — the thing that says whether this is a
            // truncated copy or a permissions problem — is in the log now instead
            // of nowhere.
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
    ///
    /// - Returns: whether a restore actually landed. Callers that must act only
    ///   on a REAL restore — identity adoption (008 H5c) — need to distinguish
    ///   that from the several ways this returns having quietly done nothing.
    @discardableResult
    static func applyPendingRestore(snapshotsDir: URL, livePath: URL) -> Bool {
        let fm = FileManager.default
        let marker = snapshotsDir.appendingPathComponent(".pending-restore")
        // No marker is the ordinary launch, so it is not read as a failure. A
        // marker that EXISTS and will not read is a restore the user asked for and
        // will not get, silently — that one is logged.
        guard fm.fileExists(atPath: marker.path) else { return false }
        guard let raw = attempt("reading the pending-restore marker", {
            try String(contentsOf: marker, encoding: .utf8)
        }) else { return false }
        // A marker that survives is a restore that runs AGAIN on the next launch —
        // over a library that has already been restored once, moving the live DB
        // aside a second time.
        defer {
            attempt("clearing the pending-restore marker") { try fm.removeItem(at: marker) }
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = snapshotsDir.appendingPathComponent(name)
        guard !name.isEmpty, fm.fileExists(atPath: snapshot.path),
              attempt("integrity-checking the staged snapshot \(name)", {
                  try AppServices.isHealthy(databaseFileAt: snapshot)
              }) == true
        else { return false }

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
            // If this write fails, the next launch runs the ORPHAN GC instead of
            // the post-restore reconcile — and reaps every blob captured after the
            // snapshot, which is precisely the media the reconcile exists to
            // protect. The restore itself has already succeeded, so this cannot
            // throw; it can be loud.
            attempt("writing the just-restored marker") {
                try "".write(
                    to: snapshotsDir.appendingPathComponent(".just-restored"),
                    atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            staging.remove()
            AppLog.model.error(
                "snapshots: installing the staged restore failed: \(String(describing: error), privacy: .public)")
            // Roll the live DB back if we moved it aside but couldn't install.
            // THIS is the failure that matters most in the file: if the rollback
            // also fails, the app is about to open with no database where its
            // database used to be, and the user's library is sitting under a
            // `library.corrupt-<epoch>.sqlite` name nobody has told them about.
            if !live.exists, aside.exists {
                if attempt("rolling the live database back after a failed restore", {
                    try aside.move(to: live)
                }) == nil {
                    AppLog.model.fault(
                        "snapshots: the live database is NOT in place — it is at \(aside.base.lastPathComponent, privacy: .public)")
                }
            }
            return false
        }
    }

    // MARK: - Library identity adoption (008 H5c)

    /// The marker naming the library id a pending restore came FROM.
    private var identityMarker: URL {
        directory.appendingPathComponent(".pending-library-id")
    }

    /// Record that the staged restore came from the backup of `libraryID`, so
    /// the next launch adopts that identity once the restore actually lands.
    ///
    /// Why deferred rather than written now: adopting immediately would point
    /// this library's backups at `<target>/<libraryID>/` while it still holds
    /// its OWN database. A user who staged a restore and then ran a backup
    /// instead of relaunching would overwrite the very backup they were about to
    /// restore from — destroying the recovery point on the way to using it. So
    /// the id is only a request until a restore has actually happened.
    func stageIdentityAdoption(_ libraryID: String) throws {
        try libraryID.write(to: identityMarker, atomically: true, encoding: .utf8)
    }

    /// At bootstrap, immediately after ``applyPendingRestore(snapshotsDir:livePath:)``:
    /// adopt the restored backup's library id, so this library keeps backing up
    /// into the folder it was restored from instead of stranding it.
    ///
    /// The marker is consumed either way — a request that didn't apply must not
    /// sit around waiting to fire after some unrelated future restore.
    ///
    /// - Parameter restored: what `applyPendingRestore` returned. `false` means
    ///   the swap did not happen (a missing or unhealthy file), and the library
    ///   still holds its own database — so it is still its own library, and
    ///   changing its identity would be a lie with teeth.
    /// - Returns: whether an identity was adopted.
    @discardableResult
    static func applyPendingIdentityAdoption(
        snapshotsDir: URL, libraryRoot: URL, restored: Bool
    ) -> Bool {
        let marker = snapshotsDir.appendingPathComponent(".pending-library-id")
        // As with the restore marker: absent is ordinary, unreadable is not.
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        guard let raw = attempt("reading the pending-library-id marker", {
            try String(contentsOf: marker, encoding: .utf8)
        }) else { return false }
        // "Consumed either way" is this method's stated contract (above), and the
        // removal is what makes it true. A marker that survives fires after some
        // unrelated FUTURE restore and adopts an identity nobody asked for.
        attempt("clearing the pending-library-id marker") {
            try FileManager.default.removeItem(at: marker)
        }
        guard restored else { return false }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try LibraryIdentity.adopt(id, root: libraryRoot)
            return true
        } catch {
            // A malformed id is refused by `adopt` (it becomes a path
            // component). The restore itself already succeeded, so this is a
            // degraded backup target, not a failed recovery — log and carry on.
            AppLog.model.error("restore identity adoption failed: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - The launch blob pass (099 · 16A)

    /// What a launch should do about blob files.
    ///
    /// Three states, and the third is the new one. Before 16A the choice was
    /// binary — reconcile after a restore, otherwise SWEEP — and the sweep
    /// enumerates every blob file in the library on every single launch, to find
    /// orphans that exist only if a delete happened and was never undone. On a
    /// 20,000-item library that is a full directory walk at launch, almost always
    /// to discover that there is nothing to reclaim.
    nonisolated enum LaunchBlobPass: Equatable {
        /// The first launch after a restore: report both divergence directions,
        /// reap nothing (008 review · 3A). The restored database is older than the
        /// disk, so "unreferenced" includes media captured after the snapshot.
        case reconcile
        /// A delete left orphans behind. Walk the blobs and reclaim them.
        case sweep
        /// Nothing has been deleted since the last completed sweep — so nothing on
        /// disk can be unreferenced, and there is nothing to walk.
        case none
    }

    /// The launch decision, as a pure function of the two markers.
    ///
    /// Restore wins, and that is not arbitrary: the marker says the database is
    /// older than the disk, and a sweep in that state trashes media the reconcile
    /// exists to protect. A library that was restored AND has a pending GC keeps
    /// its `.gc-pending` marker for the next ordinary launch — the orphans are
    /// still there and still reclaimable, just not today.
    nonisolated static func launchBlobPass(justRestored: Bool, gcPending: Bool) -> LaunchBlobPass {
        if justRestored { return .reconcile }
        return gcPending ? .sweep : .none
    }

    /// The marker that says "a delete left blobs behind; sweep at the next
    /// launch". Written by the delete, consumed by the sweep.
    nonisolated static func gcPendingMarker(in snapshotsDir: URL) -> URL {
        snapshotsDir.appendingPathComponent(".gc-pending")
    }

    /// Record that a delete has left unreferenced blobs on disk.
    ///
    /// Best-effort like every other marker here: a delete must not fail because a
    /// hint file could not be written. A marker that goes missing costs a sweep
    /// that does not happen, and the blobs it would have reclaimed are picked up
    /// by the next delete's sweep — the cost is disk, not correctness. Logged
    /// nonetheless, because "my library never reclaims space" is otherwise
    /// untraceable.
    nonisolated static func markGCPending(snapshotsDir: URL) {
        attempt("marking the library for a blob sweep") {
            try FileManager.default.createDirectory(
                at: snapshotsDir, withIntermediateDirectories: true)
            try "".write(
                to: gcPendingMarker(in: snapshotsDir), atomically: true, encoding: .utf8)
        }
    }

    /// Whether a delete has left blobs to reclaim.
    nonisolated static func hasGCPending(snapshotsDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: gcPendingMarker(in: snapshotsDir).path)
    }

    /// Clear the marker — **only after a sweep that actually completed**.
    ///
    /// A sweep that gave up (the referenced-set read failed) must leave it, or the
    /// orphans it did not look at become invisible until the next delete.
    nonisolated static func clearGCPending(snapshotsDir: URL) {
        let marker = gcPendingMarker(in: snapshotsDir)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        attempt("clearing the gc-pending marker") {
            try FileManager.default.removeItem(at: marker)
        }
    }

    /// Consume the "a restore just landed" marker: `true` exactly once after a
    /// successful ``applyPendingRestore``. The caller runs the post-restore blob
    /// reconcile (report, don't reap) in place of that launch's orphan GC.
    func consumeJustRestored() -> Bool {
        let marker = directory.appendingPathComponent(".just-restored")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        // A marker that will not clear pins this library on the post-restore path
        // forever: every launch reconciles and reports instead of reclaiming, so
        // orphaned blobs accumulate and the user is told about them each time.
        Self.attempt("clearing the just-restored marker") {
            try FileManager.default.removeItem(at: marker)
        }
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
///
/// `nonisolated` because it is built and read inside the reconcile's
/// `Task.detached`: under this target's MainActor-by-default, a pure value type
/// infers main-actor isolation and cannot be constructed off-main (see 285).
nonisolated struct PostRestoreBlobReport: Equatable {
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
