//
//  LibraryStatsController.swift
//  AtelierRefs
//
//  016 · A — the app-side orchestrator for library measurement and maintenance:
//  run the work OFF the main actor, publish progress for the Settings section,
//  and report honestly what happened.
//
//  Shaped after `BackupController` (008 H5), which was itself shaped after
//  `ExportController` (052 · B3) — deliberately, and for the third time: same
//  `@Published progress`, same `CancelFlag`, same "the work is a detached task
//  and the state is `@MainActor`" split, same monotonic `seq` on the report so
//  two identical back-to-back outcomes still trip `.onChange`. A fourth shape
//  for long-running work would be a fourth set of bugs.
//
//  Lives here rather than as `@State` on `SettingsView` for the same reason
//  `BackupController` does: that window can be closed and reopened mid-run, and
//  view state would go with it — showing a fresh "Measure Library" button over a
//  scan that is still walking a hundred thousand files.
//
//  What it deliberately is NOT: an engine. Every job below is a call into a
//  service that already existed and is already tested — `MediaReaper`,
//  `AppServices.integrityCheck`, `AppServices.reconcileOrphanedKnownItems` —
//  plus the read-only `LibraryStorageScanner`. Nothing here decides what to
//  delete.
//

import AtelierCore
import AtelierIngestion
import Combine
import Foundation
import os

/// One measurement of the library: sizes, counts, and the largest files.
/// `Sendable` so it can be built off the main actor and handed back whole.
struct LibraryStatsSnapshot: Sendable, Equatable {
    var usage: LibraryStorageUsage
    var countsByKind: [AssetKind: Int]
    var countsByPlatform: [Platform: Int]
    /// Top-N by on-disk size. Sizes come from THIS scan and are then read from
    /// here — the "cached, never `stat` per render" rule the 016 brief sets.
    var largest: [LargestItem]
    /// What the archive shelf is holding (023 · A4). Measured here rather than
    /// on the shelf pane, because "what can I reclaim" is a LIBRARY question and
    /// this is the surface that answers those — and because the shelf pane
    /// deliberately shows items, not accounting.
    var archived: ArchivedUsage = .empty
    var scannedAt: Date

    /// Total assets across every kind — the headline count.
    var assetCount: Int { countsByKind.values.reduce(0, +) }
}

@MainActor
final class LibraryStatsController: ObservableObject {

    // MARK: - Jobs

    /// The one-at-a-time jobs this controller runs. They share a controller
    /// because they share a library: measuring while an orphan sweep trashes
    /// files would produce a total that was never true.
    /// `nonisolated` because the off-main run reads its `rawValue` and its
    /// wording while classifying an outcome — the type is a bag of constants,
    /// and inheriting the controller's `@MainActor` would make reading a string
    /// literal an actor hop.
    nonisolated enum Job: String, Sendable, Equatable, CaseIterable {
        /// Measure the library (read-only).
        case scan
        /// `MediaReaper.reapOrphanedBlobs` over the referenced set.
        case orphanSweep
        /// Regenerate missing thumbnail tiers.
        case thumbnails
        /// `PRAGMA integrity_check` on the live database.
        case integrity
        /// `AppServices.reconcileOrphanedKnownItems`.
        case reconcile

        /// The button title.
        var title: String {
            switch self {
            case .scan: "Measure Library"
            case .orphanSweep: "Run Orphan Sweep…"
            case .thumbnails: "Regenerate Thumbnails…"
            case .integrity: "Verify Integrity…"
            case .reconcile: "Reconcile Import Ledger…"
            }
        }

        /// What the row says while it runs.
        var runningTitle: String {
            switch self {
            case .scan: "Measuring…"
            case .orphanSweep: "Sweeping…"
            case .thumbnails: "Regenerating…"
            case .integrity: "Verifying…"
            case .reconcile: "Reconciling…"
            }
        }

        /// Whether this job can report a real fraction. The two database jobs
        /// cannot — a `PRAGMA` is opaque — so the view shows a spinner rather
        /// than a bar that pretends. The orphan sweep can't either: its
        /// denominator lives inside `MediaReaper`, and inventing a hook there to
        /// feed a progress bar would be changing tested machinery for cosmetics.
        var reportsProgress: Bool {
            switch self {
            case .scan, .thumbnails: true
            case .orphanSweep, .integrity, .reconcile: false
            }
        }

        /// Whether the confirmation's action button reads as destructive.
        var isDestructive: Bool { self == .orphanSweep }

        /// The confirmation dialog's title. Every job is individually confirmed
        /// — including the read-only ones, because a scan of a large library is
        /// minutes of disk the user did not ask to spend.
        var confirmTitle: String {
            switch self {
            case .scan: "Measure the library?"
            case .orphanSweep: "Run the orphan sweep?"
            case .thumbnails: "Regenerate missing thumbnails?"
            case .integrity: "Verify library integrity?"
            case .reconcile: "Reconcile the import ledger?"
            }
        }

        /// The confirmation's action button.
        var confirmVerb: String {
            switch self {
            case .scan: "Measure"
            case .orphanSweep: "Sweep"
            case .thumbnails: "Regenerate"
            case .integrity: "Verify"
            case .reconcile: "Reconcile"
            }
        }

        /// What the job will actually do, in the user's terms — including the
        /// part they'd want to know before pressing it.
        var confirmMessage: String {
            switch self {
            case .scan:
                "Walks every file in the Library to measure it. Nothing is "
                    + "changed. On a large library this takes a while; you can stop it."
            case .orphanSweep:
                "Moves media files that no item references any more to the Trash. "
                    + "Your items are untouched, and the files stay in the Trash "
                    + "until you empty it."
            case .thumbnails:
                "Rebuilds preview images that are missing from the Library. "
                    + "Originals and items are untouched."
            case .integrity:
                "Asks SQLite to check the database for corruption. Read-only."
            case .reconcile:
                "Forgets import records whose media is no longer in the Library, "
                    + "so those sources can be imported again. No items are removed."
            }
        }
    }

    // MARK: - Report

    /// The terminal outcome of one job. `nonisolated` for the same reason
    /// ``Job`` is: it is built off the main actor and handed across.
    nonisolated struct Report: Sendable, Equatable {
        enum Outcome: Equatable {
            /// Finished, with the sentence the user reads.
            case success(String)
            case cancelled
            case failed(String)
        }

        var job: Job
        var outcome: Outcome
        /// Monotonic — trips `.onChange` even for identical back-to-back reports
        /// (052 · B3's rule: "no orphans found" twice must still be two events).
        var seq: Int

        /// The status line. Cancellation says so plainly: a user who pressed
        /// Stop must never be told the job failed.
        var message: String {
            switch outcome {
            case .success(let text): text
            case .cancelled: "\(job.runningTitle.replacingOccurrences(of: "…", with: "")) stopped."
            case .failed(let text): text
            }
        }

        var isFailure: Bool {
            if case .failed = outcome { return true }
            return false
        }
    }

    // MARK: - State

    /// Whether a job is in flight — gates every button and shows the run row.
    @Published private(set) var isRunning = false
    /// Which job, for the row's label and the progress style.
    @Published private(set) var runningJob: Job?
    /// 0…1 for the jobs that can measure themselves; meaningless otherwise
    /// (see ``Job/reportsProgress``).
    @Published private(set) var progress: Double = 0
    /// The last measurement. `nil` until the user asks for one — the scan is
    /// never run unasked, because walking a large library at launch is exactly
    /// the kind of unexplained disk churn this app shouldn't have.
    @Published private(set) var stats: LibraryStatsSnapshot?
    /// The last job's outcome.
    @Published private(set) var lastReport: Report?
    /// Whether the library has changed since ``stats`` was measured. Set by the
    /// actions that move bytes; cleared by the next successful measurement.
    /// Figures that were true five seconds ago and are labelled as current are
    /// the exact failure this feature exists to end, so the pane says when it
    /// knows it is out of date rather than quietly being wrong.
    @Published private(set) var isStale = false

    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?
    private var reportSeq = 0

    /// How many rows the largest-items list shows.
    static let largestItemsLimit = 10

    // MARK: - Cancelling

    /// Stop the running job. Both signals are sent for the reason
    /// `BackupController` documents: the flag is what the per-file loop reads,
    /// and cancelling the task stops everything downstream of the current
    /// `await`. ``run`` knows to read the flag BEFORE classifying whatever the
    /// teardown throws.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    /// Forget the last measurement — called when the library closes, so the
    /// section can't show sizes for a library that is no longer open.
    func forgetStats() {
        stats = nil
        isStale = false
    }

    /// Record that the library changed under the last measurement (a delete
    /// from the largest-items list, a completed sweep). A no-op when there is
    /// nothing measured to invalidate.
    func markStale() {
        isStale = stats != nil
    }

    // MARK: - Jobs

    /// Measure the library: sizes per tier, counts by kind and platform, and the
    /// largest files. Read-only from end to end.
    func measure(services: AppServices, store: MediaStore, limit: Int = largestItemsLimit) {
        run(.scan) { flag, onProgress in
            // The filesystem half. Goes through the store's injected
            // `LibraryLayout` — never the container path (016 · C).
            let scan = try LibraryStorageScanner(layout: store.layout)
                .scan(isCancelled: { flag.isCancelled }, onProgress: onProgress)
            // The database half.
            let kinds = try await services.assetCountsByKind()
            let platforms = try await services.assetCountsByPlatform()
            let blobs = try await services.blobUsage()
            let archived = try await services.archivedUsage()
            return LibraryStatsSnapshot(
                usage: scan.usage, countsByKind: kinds, countsByPlatform: platforms,
                largest: LibraryStats.largestItems(
                    blobs: blobs, sizes: scan.blobSizes, limit: limit),
                archived: archived,
                scannedAt: scan.scannedAt)
        } finish: { [weak self] snapshot in
            self?.stats = snapshot
            self?.isStale = false
            return "Measured \(LibraryStatsCopy.items(snapshot.assetCount)) — "
                + "\(LibraryStatsCopy.size(snapshot.usage.totalBytes)) in total."
        }
    }

    /// Trash every stored blob no asset references any more — the launch
    /// orphan-GC, made user-invokable.
    func runOrphanSweep(services: AppServices, store: MediaStore) {
        run(.orphanSweep) { flag, _ in
            // `referencedBlobHashes()`, NOT `referencedBlobs()`. The reaper's
            // keep-set parameter is `Set<String>` because it derives each
            // ORPHAN's file extension from the file it found on disk — it never
            // needs a LIVE blob's mime type. Passing `[BlobRef]` here would mean
            // reading a column, mapping it into a descriptor and discarding it.
            // (`referencedBlobs()` earns its keep on the thumbnail job below,
            // which does need the mime: it has to open the file and know whether
            // it's a video.)
            let referenced = try await services.referencedBlobHashes()
            // Checked between the read and the reap: a Stop pressed during the
            // query must not still trash files.
            if flag.isCancelled { throw CancellationError() }
            return MediaReaper(store: store).reapOrphanedBlobs(referenced: referenced).count
        } finish: { [weak self] trashed in
            guard trashed > 0 else { return "No orphaned media found — nothing to reclaim." }
            self?.markStale()
            return "Moved \(trashed) unreferenced file\(trashed == 1 ? "" : "s") to the Trash."
        }
    }

    /// Rebuild the thumbnail tiers that are missing from disk.
    func regenerateThumbnails(services: AppServices, store: MediaStore) {
        run(.thumbnails) { flag, onProgress in
            // `referencedBlobs()` here: the backfill must FIND each blob's file
            // (the mime names its extension) and know whether to render a video
            // poster frame or decode an image. Hashes alone can't answer either.
            let blobs = try await services.referencedBlobs()
            return try await ThumbnailBackfill(store: store).run(
                blobs: blobs, isCancelled: { flag.isCancelled }, onProgress: onProgress)
        } finish: { [weak self] result in
            if result.didWork { self?.markStale() }
            if result.generated == 0 {
                return result.skipped == 0
                    ? "Every item already has its previews."
                    : "Nothing to rebuild — \(result.skipped) item(s) have no media on disk."
            }
            var text = "Rebuilt \(result.generated) preview(s) for "
                + "\(LibraryStatsCopy.items(result.repaired))."
            if result.skipped > 0 {
                text += " \(result.skipped) item(s) were skipped — no readable media."
            }
            return text
        }
    }

    /// `PRAGMA integrity_check` on the live database.
    func verifyIntegrity(services: AppServices) {
        run(.integrity) { _, _ in
            try await services.integrityCheck()
        } finish: { healthy in
            healthy
                ? "Database integrity check passed."
                : "The database reported errors. Restore a snapshot (File ▸ Restore "
                    + "from Snapshot…) and export diagnostics before continuing."
        }
    }

    /// Forget import-ledger rows whose blob no longer has an asset.
    func reconcileKnownItems(services: AppServices) {
        run(.reconcile) { _, _ in
            try await services.reconcileOrphanedKnownItems().count
        } finish: { reconciled in
            reconciled == 0
                ? "The import ledger is already consistent."
                : "Reconciled \(reconciled) import record(s) — those sources can be "
                    + "imported again."
        }
    }

    // MARK: - The run itself

    /// Run one job off the main actor, publish its outcome on the main actor.
    ///
    /// `work` is `@Sendable` and runs in a DETACHED task so it never inherits
    /// this actor — a synchronous filesystem walk scheduled onto the main actor
    /// would freeze the app for exactly as long as the library is large.
    /// `finish` runs back on the main actor: it applies whatever state the job
    /// produced and returns the sentence the user reads.
    private func run<T: Sendable>(
        _ job: Job,
        work: @escaping @Sendable (CancelFlag, @escaping @Sendable (Double) -> Void) async throws -> T,
        finish: @escaping @MainActor @Sendable (T) -> String
    ) {
        guard !isRunning else { return }
        isRunning = true
        runningJob = job
        progress = 0

        let flag = CancelFlag()
        cancelFlag = flag

        // Progress arrives from the job's own loop; hop each report back to the
        // main actor. The jobs throttle to whole percents, so this is ~100 hops
        // per run rather than one per file.
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }

        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let value = try await work(flag, onProgress)
                await MainActor.run {
                    guard let self else { return }
                    self.publish(Report(job: job, outcome: .success(finish(value)), seq: 0))
                }
            } catch {
                // The flag is read FIRST, before the error is classified — the
                // lesson `BackupController` learned the hard way (008 H5). Stop
                // tears down the surrounding task as well as setting the flag,
                // so whatever was in flight — a GRDB read, the size loop — throws
                // on the way out. Those throws are a CONSEQUENCE of the user
                // pressing Stop; reporting them as a failure would tell the user
                // something went wrong when nothing did.
                let cancelled = flag.isCancelled || error is CancellationError
                // The message is rendered HERE, before the actor hop, so no
                // non-`Sendable` error value crosses it.
                let message = "Couldn't \(job.confirmVerb.lowercased()) the library: "
                    + error.localizedDescription
                if !cancelled {
                    AppLog.model.error(
                        "library job \(job.rawValue, privacy: .public) failed: \(error, privacy: .public)")
                }
                await MainActor.run {
                    guard let self else { return }
                    self.publish(Report(
                        job: job, outcome: cancelled ? .cancelled : .failed(message), seq: 0))
                }
            }
        }
    }

    /// Finalise state + stamp the report's monotonic sequence.
    private func publish(_ report: Report) {
        isRunning = false
        runningJob = nil
        cancelFlag = nil
        task = nil
        reportSeq += 1
        var stamped = report
        stamped.seq = reportSeq
        if case .success = report.outcome, report.job.reportsProgress { progress = 1 }
        lastReport = stamped
    }
}
