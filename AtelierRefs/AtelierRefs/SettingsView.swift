//
//  SettingsView.swift
//  AtelierRefs
//
//  010 · Phase 2 — the standard macOS Settings scene (⌘,). A home for the pieces
//  that previously had none: the browser-capture pairing secret (copy /
//  regenerate), the on-disk Library location, and a way to replay the first-run
//  setup guide. Shares the app's single ``IngestionModel`` (lifted to App level).
//

import AtelierCore
import AtelierIngestion
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: IngestionModel
    /// Observed separately from `model` (008 · H5): a nested `ObservableObject`
    /// doesn't propagate its changes through its owner, so progress ticks would
    /// never reach this view otherwise.
    @ObservedObject var backup: BackupController
    /// Observed separately for the same reason as `backup` (008 · H5c) — the
    /// restore's scan results and progress live on its own controller.
    @ObservedObject var restore: RestoreController
    /// Observed separately for the same reason as `backup` (008 · H5d) — the
    /// re-hash check's progress and verdict live on its own controller.
    @ObservedObject var verify: BackupVerifyController
    /// Observed separately for the same reason as `backup` (008 · H6) — the
    /// archive's progress ticks live on its own controller.
    @ObservedObject var archive: ArchiveExportController
    /// Observed separately for the same reason as `archive` (008 · H7) — the
    /// import's progress ticks live on its own controller.
    @ObservedObject var archiveImport: ArchiveImportController
    /// Observed separately for the same reason as `backup` (016 · A) — a scan's
    /// progress ticks live on the controller, not on `model`.
    @ObservedObject var libraryStats: LibraryStatsController
    /// Owned by the app (not this scene), so flipping a toggle here reaches the grid
    /// that is already on screen.
    @ObservedObject var gridPrefs: GridViewPreferences
    /// The ambient clipboard watcher (013 · K3). Observed separately for the same
    /// reason `backup` is — it is a nested `ObservableObject` on the model, so its
    /// pause / library-bound changes wouldn't reach this row otherwise.
    @ObservedObject var clipboard: ClipboardWatcher

    /// The first-run flag ``ContentView`` gates onboarding on — flipping it false
    /// here re-shows the setup guide on the next main-window appearance.
    @AppStorage("AtelierDidCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var confirmRegenerate = false
    /// The maintenance job awaiting its own confirmation — every one of them is
    /// individually confirmable (016 · A), so this is a job, not a Bool.
    @State private var confirmingJob: LibraryStatsController.Job?
    /// The largest-items row awaiting delete confirmation.
    @State private var deletingItem: LargestItem?

    var body: some View {
        Form {
            captureSection
            clipboardSection
            gridSection
            librarySection
            backupSection
            archiveSection
            setupSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        // Re-resolve on every appearance: the window outlives any single visit,
        // and a drive can be unplugged between two of them.
        .onAppear {
            model.refreshBackupFolder()
            model.refreshPendingRestore()
        }
    }

    // MARK: - Browser capture

    private var captureSection: some View {
        Section("Browser Capture") {
            LabeledContent("Endpoint") {
                Text(CaptureCopy.endpoint(port: model.capturePort))
                    .textSelection(.enabled)
                    .foregroundStyle(model.captureEndpointRunning ? .primary : .secondary)
                    // 099 · P2 — the ⌘, flow's proof that the second window is THIS
                    // scene and not a second main window. On the leaf `Text`, not on
                    // the `LabeledContent` around it.
                    .accessibilityIdentifier(AccessibilityID.settingsCaptureEndpoint)
            }
            LabeledContent("Pairing token") {
                HStack(spacing: 8) {
                    CaptureTokenText(token: model.captureToken)
                    CaptureTokenCopyButton(model: model)
                }
            }
            Button("Regenerate Token…", role: .destructive) { confirmRegenerate = true }
                .disabled(!CaptureCopy.hasToken(model.captureToken))
                .confirmationDialog(
                    "Regenerate the pairing token?",
                    isPresented: $confirmRegenerate, titleVisibility: .visible
                ) {
                    // Return commits, as in every confirmation dialog here — a
                    // `role: .destructive` button is left unbound otherwise (see
                    // ``ContentView``'s delete dialog for the mechanism).
                    Button("Regenerate", role: .destructive) { model.regenerateCaptureToken() }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The current token stops working immediately. You'll need to "
                         + "paste the new token into the Chrome extension to re-pair.")
                }
            CaptureTokenExplainer()
        }
    }

    // MARK: - Clipboard capture (013 · K3)

    /// The one place ambient capture can be turned on. Off by default, and the
    /// copy under it states the three limits plainly rather than reassuringly —
    /// somebody deciding whether to let an app watch their clipboard deserves the
    /// actual rules, not a promise that it is "private".
    private var clipboardSection: some View {
        Section("Clipboard Capture") {
            Toggle("Save copied images automatically", isOn: Binding(
                get: { clipboard.isEnabled },
                set: { clipboard.setEnabled($0) }))
                .disabled(!clipboard.isAvailable)
            Text("While this is on, any image you copy anywhere on your Mac is added "
                 + "to Unsorted, and a clipboard icon appears in the menu bar for as "
                 + "long as it's running — click it to pause or turn it off. Copied "
                 + "text and files are ignored, and so is anything a password manager "
                 + "marks as concealed.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !clipboard.isAvailable {
                Label("Available once the library finishes opening.",
                      systemImage: "clock")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } else if clipboard.isPaused {
                Label("Paused from the menu bar — capture resumes from there.",
                      systemImage: "pause.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Location") {
                Text(model.libraryRoot?.path(percentEncoded: false) ?? "Opening…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Show in Finder") { model.revealLibraryInFinder() }
                .disabled(model.libraryRoot == nil)
            Text("Your images, database, and thumbnails live here. Snapshots (File ▸ "
                 + "Snapshot Now) are your in-app recovery points.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            // 016 · A — storage, the largest files, and the cleanup jobs. Same
            // section as Location on purpose: the library AS STORAGE is one
            // subject, and Backup sits directly below it.
            libraryRunRow
            storageRows
            countRows
            largestItemsRows
            cleanupRows
        }
        .confirmationDialog(
            confirmingJob?.confirmTitle ?? "",
            isPresented: Binding(
                get: { confirmingJob != nil },
                set: { if !$0 { confirmingJob = nil } }),
            titleVisibility: .visible,
            presenting: confirmingJob
        ) { job in
            // Stated rather than left to the role: a NON-destructive job already got
            // Return for free, a destructive one silently didn't, so the same dialog
            // answered the keyboard differently depending on which job opened it.
            Button(job.confirmVerb, role: job.isDestructive ? .destructive : nil) {
                model.runLibraryJob(job)
                confirmingJob = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { confirmingJob = nil }
        } message: { job in
            Text(job.confirmMessage)
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: Binding(
                get: { deletingItem != nil },
                set: { if !$0 { deletingItem = nil } }),
            titleVisibility: .visible,
            presenting: deletingItem
        ) { item in
            Button("Delete", role: .destructive) {
                model.deleteLibraryItem(item)
                deletingItem = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { deletingItem = nil }
        } message: { item in
            Text(LibraryStatsCopy.deleteConfirmation(for: item))
        }
    }

    /// "Measure Library" / "Stop", the progress while a job is in flight, and
    /// the last job's status line. One row for every job, because only one runs
    /// at a time — measuring while a sweep trashes files would produce a total
    /// that was never true.
    @ViewBuilder
    private var libraryRunRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(LibraryStatsController.Job.scan.title) {
                confirmingJob = .scan
            }
            .disabled(!model.canRunLibraryJob)
            if libraryStats.isRunning, let job = libraryStats.runningJob {
                Button("Stop") { libraryStats.cancel() }
                // Not `.destructive`: stopping a measurement destroys nothing,
                // and stopping a sweep keeps every file already reclaimed.
                Text(job.runningTitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                if job.reportsProgress {
                    ProgressView(value: libraryStats.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        if let report = libraryStats.lastReport, !libraryStats.isRunning {
            if report.isFailure {
                Label(report.message, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(report.message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The per-tier size breakdown. Measured apart rather than summed: the
    /// separation is what surfaces the regenerable figure.
    @ViewBuilder
    private var storageRows: some View {
        if let stats = libraryStats.stats {
            LabeledContent("Total") {
                Text(LibraryStatsCopy.size(stats.usage.totalBytes)).monospacedDigit()
            }
            LabeledContent("Database") {
                Text(LibraryStatsCopy.size(stats.usage.databaseBytes)).monospacedDigit()
            }
            ForEach(LibraryStorageTier.allCases, id: \.self) { tier in
                LabeledContent(LibraryStatsCopy.tier(tier)) {
                    Text(LibraryStatsCopy.size(stats.usage.bytes(for: tier))).monospacedDigit()
                }
            }
            Text(LibraryStatsCopy.storageExplainer(stats.usage))
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(LibraryStatsCopy.measured(at: stats.scannedAt, isStale: libraryStats.isStale))
                .font(Theme.Typography.caption)
                // Spelled out rather than `? .orange : .secondary`: the two branches are
                // now different STYLE types (a `Color` token and the system hierarchy),
                // so the ternary needs both sides named to infer.
                .foregroundStyle(libraryStats.isStale ? Theme.Colors.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Counts by kind and by platform. Empty categories are omitted rather than
    /// shown as zero — a library with no videos should not have a Videos row.
    @ViewBuilder
    private var countRows: some View {
        if let stats = libraryStats.stats {
            LabeledContent("Items") {
                Text("\(stats.assetCount)").monospacedDigit()
            }
            ForEach(LibraryStats.ordered(stats.countsByKind)) { entry in
                LabeledContent(LibraryStatsCopy.kind(entry.key)) {
                    Text("\(entry.count)").monospacedDigit()
                }
            }
            ForEach(LibraryStats.ordered(stats.countsByPlatform)) { entry in
                LabeledContent(LibraryStatsCopy.platform(entry.key)) {
                    Text("\(entry.count)").monospacedDigit()
                }
            }
            // The shelf (023 · A4) — omitted when empty, following this
            // section's rule that a library with no videos gets no Videos row.
            // It sits below the kind / platform breakdown because it is not one
            // of them: those partition the library, this one names a state a few
            // of its items are in.
            if !stats.archived.isEmpty {
                LabeledContent("Archived") {
                    Text(LibraryStatsCopy.archived(stats.archived))
                        .monospacedDigit()
                }
            }
        }
    }

    /// The largest files on disk. Sizes are read from the cached measurement —
    /// nothing here `stat`s a file per render (016 · A).
    @ViewBuilder
    private var largestItemsRows: some View {
        if let stats = libraryStats.stats, !stats.largest.isEmpty {
            DisclosureGroup("Largest Items") {
                ForEach(stats.largest) { item in
                    largestItemRow(item)
                }
            }
        }
    }

    private func largestItemRow(_ item: LargestItem) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LibraryStatsCopy.title(for: item))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(LibraryStatsCopy.subtitle(for: item))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            // A menu rather than three buttons: the Settings form is 460pt wide
            // and three labelled controls per row would leave no width for the
            // name, which is the only thing that identifies the item.
            Menu {
                Button("Reveal in Finder") { model.revealInFinder(largestItem: item) }
                Button("Open") { model.openBlob(largestItem: item) }
                Divider()
                Button("Delete…", role: .destructive) { deletingItem = item }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// The cleanup jobs — every one a button on a service that already existed.
    @ViewBuilder
    private var cleanupRows: some View {
        ForEach(Self.cleanupJobs, id: \.self) { job in
            Button(job.title) { confirmingJob = job }
                .disabled(!model.canRunLibraryJob)
        }
        // Snapshot Now is the SAME call File ▸ Snapshot Now makes — reused, not
        // duplicated, so there is one manual-snapshot path in the app.
        Button("Snapshot Now") { model.snapshotNow() }
            .disabled(model.snapshotManager == nil || model.isSnapshotting)
        Text("Cleanup acts on files, never on your items: the sweep only trashes "
             + "media nothing references, and reconciling only forgets import "
             + "records whose media is gone. Each asks before it runs.")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The cleanup jobs in the order the section lists them — `scan` is excluded
    /// because it has its own row at the top.
    private static let cleanupJobs: [LibraryStatsController.Job] =
        [.orphanSweep, .thumbnails, .integrity, .reconcile]

    // MARK: - Grid (307)

    private var gridSection: some View {
        Section("Grid") {
            Toggle("Group carousels", isOn: $gridPrefs.groupCarousels)
            Text("Show a multi-image post — an Instagram carousel, a multi-photo "
                 + "tweet — as one tile with a count, instead of one tile per image. "
                 + "Click the ⧉ badge on a tile to look through the post in place.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Off-device backup (008 H4)

    private var backupSection: some View {
        Section("Backup") {
            LabeledContent("Folder") {
                Text(backupFolderText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(model.backupFolderURL == nil ? .secondary : .primary)
            }
            HStack {
                Button(model.backupFolder.hasFolder ? "Change Folder…" : "Choose Folder…") {
                    BackupFolderPanel.present { url in
                        if let url { model.setBackupFolder(url) }
                    }
                }
                .disabled(backup.isRunning)
                if model.backupFolder.hasFolder {
                    Button("Clear", role: .destructive) { model.clearBackupFolder() }
                        .disabled(backup.isRunning)
                }
            }
            // Shown only when something is actually wrong — an unreachable drive,
            // a revoked grant, a folder inside the library.
            if let message = model.backupFolderMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            backupRunRow
            backupCadenceRow
            backupVerifyRow
            Text(BackupTarget.explainer)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            restoreRow
        }
        .sheet(isPresented: $model.showRestoreBackups) {
            RestoreBackupSheet(model: model, restore: restore)
        }
    }

    /// "Restore from Backup…" / "Stop", the progress while a restore copies, and
    /// the last attempt's status (008 · H5c).
    ///
    /// Below the backup rows and behind a sheet, not beside "Back Up Now": the
    /// two are not peers. One is routine and safe; the other replaces the
    /// library and relaunches the app, and it should take a deliberate second
    /// step to reach.
    @ViewBuilder
    private var restoreRow: some View {
        HStack {
            Button("Restore from Backup…") { model.beginRestoreFromBackup() }
                .disabled(!model.canRestoreBackup)
            if restore.isRunning {
                Button("Stop") { restore.cancel() }
                // Not `.destructive`: stopping a restore stages nothing, so the
                // library is left exactly as it was.
                ProgressView(value: restore.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
            }
        }
        if let status = BackupTarget.restoreStatusLine(for: restore.lastRun), !restore.isRunning {
            Text(status)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = restore.lastRun?.message, !restore.isRunning {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A staged restore is why both buttons above are disabled — say so,
        // rather than leaving the section looking broken.
        if model.hasPendingRestore, !restore.isRunning {
            Label("A restore is waiting — quit and reopen AtelierRefs to apply it.",
                  systemImage: "arrow.clockwise")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Back Up Now" / "Stop", the progress bar while a run is in flight, and
    /// the last-run line (008 · H5).
    @ViewBuilder
    private var backupRunRow: some View {
        HStack {
            Button("Back Up Now") { model.runBackupNow() }
                .disabled(!model.canRunBackup)
            if backup.isRunning {
                Button("Stop") { backup.cancel() }
                // Deliberately not `.destructive`: stopping keeps everything
                // already copied, so it destroys nothing.
                ProgressView(value: backup.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
            }
        }
        // Only once there is a target — "Never backed up" beside a "Choose
        // Folder…" button states the obvious twice.
        if model.backupFolder.hasFolder, !backup.isRunning {
            Text(BackupTarget.statusLine(for: backup.lastRun))
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        // A run that couldn't start says why, and what to do about it.
        if let message = backup.lastRun?.message, !backup.isRunning {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How often a backup runs by itself (008 · H5d).
    ///
    /// A picker in the same section as the folder, not a hidden default: the
    /// job it starts copies gigabytes to a drive or a paid-for cloud folder, and
    /// anything that can do that on its own has to be visible and switchable
    /// where it was set up.
    @ViewBuilder
    private var backupCadenceRow: some View {
        Picker("Automatically", selection: Binding(
            get: { backup.cadence },
            set: { backup.setCadence($0) })
        ) {
            ForEach(BackupCadence.allCases, id: \.self) { cadence in
                Text(cadence.label).tag(cadence)
            }
        }
        .disabled(backup.isRunning)
        // Only when there is actually a behaviour to explain.
        if backup.cadence != .manual {
            Text(BackupTarget.automaticExplainer)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The sampled re-hash check, the exhaustive one beside it, and the verdict
    /// (008 · H5d).
    ///
    /// Two buttons rather than one with a modifier key. The exhaustive check
    /// downloads the entire backup from a synced destination, which is a cost
    /// nobody should be able to start by accident — and while one is running the
    /// buttons give way to what it is doing, so "a sample" and "every file" are
    /// never confusable after the fact.
    @ViewBuilder
    private var backupVerifyRow: some View {
        HStack {
            if verify.isRunning {
                Text(verify.isExhaustive ? "Checking every file…" : "Checking a sample…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Button("Stop") { verify.cancel() }
                // Not `.destructive`: a check writes nothing, so stopping it
                // costs only the answer.
                ProgressView(value: verify.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
            } else {
                Button("Check Backup") { model.verifyBackupNow() }
                    .disabled(!model.canVerifyBackup)
                Button("Check All Files") { model.verifyBackupNow(exhaustive: true) }
                    .disabled(!model.canVerifyBackup)
            }
        }
        if let status = BackupTarget.verifyStatusLine(for: verify.lastRun), !verify.isRunning {
            Text(status)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // What it found, and that nothing was deleted because of it.
        if !verify.isRunning, let result = verify.lastRun?.result,
           let problem = BackupTarget.verifyProblem(for: result) {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Why it couldn't look at all — a different message from what it found.
        if let message = verify.lastRun?.message, !verify.isRunning {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.backupFolder.hasFolder {
            Text(BackupTarget.verifyExplainer)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The folder row's text: the resolved path, else the reason there isn't one.
    /// A chosen-but-unreachable target reads as "Unavailable" rather than blank,
    /// so the row never implies the target was forgotten (it wasn't — the
    /// bookmark is kept precisely so reconnecting a drive is enough).
    private var backupFolderText: String {
        if let url = model.backupFolderURL {
            return url.path(percentEncoded: false)
        }
        return model.backupFolder.hasFolder ? "Unavailable" : "None chosen"
    }

    // MARK: - Portable archive (008 H6)

    /// Its own section rather than a row inside Backup: the two answer different
    /// questions. Backup is "can I get this Mac's library back?"; the archive is
    /// "can I take my library somewhere else?" — a folder of images anyone can
    /// open, that this app can read back in again.
    private var archiveSection: some View {
        Section("Archive") {
            HStack {
                Button("Archive Library…") { model.archiveLibrary() }
                    .disabled(!model.canArchiveLibrary)
                if archive.isExporting {
                    Button("Stop") { archive.cancel() }
                    ProgressView(value: archive.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 140)
                }
                if !archive.isExporting, archive.lastRun?.url != nil {
                    Spacer()
                    Button("Show in Finder") { model.revealArchive() }
                }
            }
            if let status = ArchiveCopy.statusLine(for: archive.lastRun), !archive.isExporting {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = archive.lastRun?.message, !archive.isExporting {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ArchiveCopy.explainer)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Import Archive…") { model.importArchive() }
                    .disabled(!model.canImportArchive)
                if archiveImport.isImporting {
                    Button("Stop") { archiveImport.cancel() }
                    ProgressView(value: archiveImport.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 140)
                }
            }
            if let status = ArchiveImportCopy.statusLine(for: archiveImport.lastRun),
               !archiveImport.isImporting {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = archiveImport.lastRun?.message, !archiveImport.isImporting {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ArchiveImportCopy.explainer)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Setup") {
            Button("Show Setup Guide Again") { didCompleteOnboarding = false }
            Text("Re-opens the first-run walkthrough (install the extension, pair the "
                 + "token, capture something) on the main window.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            // "Which build am I looking at" (021 · R2). Two bundles with the same
            // name and the same sandbox container — a build-tree one and whatever
            // sits in /Applications — are indistinguishable once running, and a
            // stale one reads as a missing feature. This line answers it without
            // a trip to Finder.
            LabeledContent("Version") {
                Text(Self.versionLine).monospacedDigit().textSelection(.enabled)
            }
            Button("Export Diagnostics…") { model.exportDiagnostics() }
            Text("Saves a plain-text report (versions, sizes, counts) and reveals it in "
                 + "Finder — for attaching to a bug report. It contains no library content.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `version (build)` from the running bundle's Info.plist — the same two keys
    /// the diagnostics export reports, so a screenshot of this row and an exported
    /// report can never disagree.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
