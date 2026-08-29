//
//  ExportController.swift
//  AtelierRefs
//
//  052 · B3 — the window-level export orchestrator. Owns the save panel, runs
//  the render OFF the main actor (052 · 15A), publishes progress for the top-bar
//  ring, and reports the outcome for the `ToastCenter` summary (052 · 7A). One
//  instance per window, injected as an `EnvironmentObject` so both the Space
//  board's Export button and the top-bar progress icon observe the same state.
//
//  Four exports share this one controller — moodboard image/PDF, contact sheet,
//  static web page, folder of originals — because the ring, the cancel popover and
//  the toast all observe `isExporting` / `progress` / `lastReport`, and an export
//  that behaved differently from the others would be one more thing to learn for
//  no benefit.
//
//  Sharing the controller is not the same as repeating its body, and for a while
//  it was: the third and fourth exports were written by copying the second, which
//  put the "ask the flag first, never the error" cancel rule in three places at
//  once. What is shared now is spelled out rather than duplicated:
//
//   • ``runFolderJob(mappingSkips:to:write:)`` — the whole detached-write shape
//     (cancel flag, folder cleanup, outcome mapping) for BOTH folder exports;
//   • ``finish(_:mappingSkips:url:)`` — the main-actor outcome tail for all THREE
//     start paths, so `.cancelled` can never be reported as `.failed` in one of
//     them and not the others;
//   • ``SkipBreakdown`` — one vocabulary for why refs were left out, so the toast
//     can tell an expected skip from an alarming one.
//

import AppKit
import AtelierExport
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ExportController: ObservableObject {

    // MARK: - Skip reporting

    /// Why refs were left out of a finished export, in buckets the user can act on
    /// differently (011 · A2 review).
    ///
    /// The writers already return typed reasons; before this they were reduced to a
    /// single `Int` one line after being computed, which made a colour swatch that
    /// was never exportable indistinguishable from a blob that had vanished off
    /// disk. Those deserve different words: the first is noise, the second is a
    /// data-integrity signal, and a refused write is actionable.
    /// `nonisolated` (the `AssetExportItem` precedent): the app target is
    /// `MainActor` by default and this type is nested in a `@MainActor` class, but
    /// it is BUILT inside the detached write — from the writer's own skips, off the
    /// main actor. It is pure value data, so it says so to the compiler.
    nonisolated struct SkipBreakdown: Equatable, Sendable {
        /// Refs with nothing exportable to begin with — a colour swatch, a link or
        /// tweet whose image was never captured. Expected; not a problem.
        var notExportable = 0
        /// Bytes gone from disk by the time the write ran (reaped, trashed, or on an
        /// unmounted volume). Worth surfacing.
        var missingSource = 0
        /// The filesystem refused the write — permissions, a full disk. Actionable:
        /// the export is wrong, not merely partial.
        var writeFailed = 0
        /// A name that would not have stayed inside the destination folder.
        var unsafeName = 0

        var total: Int { notExportable + missingSource + writeFailed + unsafeName }
        var isEmpty: Bool { total == 0 }

        init(notExportable: Int = 0, missingSource: Int = 0,
             writeFailed: Int = 0, unsafeName: Int = 0) {
            self.notExportable = notExportable
            self.missingSource = missingSource
            self.writeFailed = writeFailed
            self.unsafeName = unsafeName
        }

        /// From a folder writer's per-file skips, plus the mapping's byte-less rows.
        init(fileSkips: [ExportSkip], notExportable: Int) {
            self.init(notExportable: notExportable)
            for skip in fileSkips {
                switch skip.reason {
                case .missingSource: missingSource += 1
                case .copyFailed: writeFailed += 1
                case .unsafeName: unsafeName += 1
                }
            }
        }

        /// From the moodboard renderer's per-element skips, plus mapping skips.
        ///
        /// `.noProvider` is a programmer error the renderer surfaces softly rather
        /// than crashing on; it is counted as a write failure because that is the
        /// bucket that says "this output is wrong", which it is.
        init(renderSkips: [SkippedElement], notExportable: Int) {
            self.init(notExportable: notExportable)
            for skip in renderSkips {
                switch skip.reason {
                case .missingImage: missingSource += 1
                case .noProvider: writeFailed += 1
                }
            }
        }
    }

    /// The terminal outcome of an export, surfaced as a toast.
    struct Report: Equatable {
        enum Outcome: Equatable {
            /// Everything asked for was written.
            case success
            /// Written, but not whole — some refs did not make it.
            ///
            /// Its own case rather than a `.success` carrying a non-zero count, for
            /// the reason `ArchiveExportController`'s `ArchiveOutcome` gives about
            /// the same situation: "usable, just not whole; saying 'succeeded' would
            /// be a lie and 'failed' would be worse". It matters more for a folder of
            /// originals than for a moodboard — 37 files where 40 were asked for look
            /// completely fine in Finder.
            case incomplete
            case cancelled
            case failed(String)
        }
        var outcome: Outcome
        /// Why refs were left out — buckets, not a bare count.
        var skipped: SkipBreakdown
        /// Where it was written (success / incomplete only).
        var url: URL?
        /// Monotonic — trips `.onChange` even for identical back-to-back reports.
        var seq: Int

        /// Whether anything landed on disk at all.
        var didWrite: Bool {
            switch outcome {
            case .success, .incomplete: return true
            case .cancelled, .failed: return false
            }
        }
    }

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastReport: Report?

    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?
    private var reportSeq = 0

    // MARK: - Entry points

    /// Present the save panel for `config`, then export `mapping` to the chosen
    /// destination. Refused (with a report) while an export is already running, or
    /// when there is nothing renderable.
    func requestExport(
        mapping: MoodboardExport.Mapping,
        config: ExportConfig,
        suggestedName: String
    ) {
        guard !refuseIfBusy() else { return }
        guard !mapping.isEmpty else {
            report(.failed("Nothing to export"),
                   skipped: SkipBreakdown(notExportable: mapping.skipped))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [config.format == .pdf ? .pdf : .png]
        panel.nameFieldStringValue = "\(suggestedName).\(config.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.start(
                elements: mapping.elements,
                provider: MoodboardURLImageProvider(urls: mapping.imageURLs),
                config: config, background: mapping.background,
                mappingSkips: mapping.skipped, to: url)
        }

        present(panel, handler)
    }

    /// Present the save panel for a static-site export (014 · S3), then write
    /// `plan` into the chosen folder. Refused (with a report) while an export is
    /// already running, and for an empty plan — an empty collection disables the
    /// action rather than producing an empty folder.
    func requestSiteExport(plan: CollectionSiteExport.Plan, suggestedName: String) {
        guard !refuseIfBusy() else { return }
        guard !plan.isEmpty else {
            report(.failed("Nothing to export"),
                   skipped: SkipBreakdown(notExportable: plan.skipped))
            return
        }

        let panel = folderPanel(
            suggestedName: suggestedName,
            message: "Choose where to write the web page folder (index.html + assets).")
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startSite(plan: plan, to: url)
        }
    }

    /// Present the save panel for a folder of ORIGINALS (011 · A2), then copy
    /// `plan`'s files into it. Refused (with a report) while an export is already
    /// running, and for an empty plan.
    ///
    /// There is no config popover ahead of this one — unlike the moodboard, contact
    /// sheet and web page, an originals export has nothing to configure. The files
    /// are the files, so the click goes straight to the save panel.
    func requestAssetExport(plan: AssetFolderExport.Plan, suggestedName: String) {
        guard !refuseIfBusy() else { return }
        guard !plan.isEmpty else {
            report(.failed("Nothing to export"),
                   skipped: SkipBreakdown(notExportable: plan.skipped))
            return
        }

        let panel = folderPanel(
            suggestedName: suggestedName,
            message: "Choose where to write the folder of original files.")
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startAssets(plan: plan, to: url)
        }
    }

    /// Cancel a running export (from the top-bar popover). Sets the render's
    /// cancel flag and tears down the wrapping task.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    // MARK: - Panels

    /// A save panel naming a FOLDER: the user is naming something new, so it is a
    /// save panel and not an open panel, and the "file" it names is a directory —
    /// hence no content type and no extension. Shared by both folder exports so
    /// they cannot drift apart on prompt or button title.
    private func folderPanel(suggestedName: String, message: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = message
        return panel
    }

    private func present(
        _ panel: NSSavePanel, _ handler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Moodboard / contact sheet render

    private func start(
        elements: [MoodboardElement],
        provider: MoodboardURLImageProvider,
        config: ExportConfig,
        background: RGBA,
        mappingSkips: Int,
        to url: URL
    ) {
        let pages = MoodboardExport.pages(for: elements, config: config)
        guard !pages.isEmpty else {
            report(.failed("Nothing to export"),
                   skipped: SkipBreakdown(notExportable: mappingSkips))
            return
        }

        let flag = beginRun()
        let onProgress = progressSink()

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                do {
                    let result = try MoodboardExport.render(
                        pages: pages, provider: provider, config: config,
                        background: background,
                        isCancelled: { flag.isCancelled }, onProgress: onProgress)
                    try result.data.write(to: url, options: .atomic)
                    return .done(SkipBreakdown(
                        renderSkips: result.skipped, notExportable: mappingSkips))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value

            // No `await`: this `Task` inherits the enclosing `@MainActor`, and
            // `finish` is a synchronous method on it, so there was never a
            // suspension here to mark. The hop already happened at `.value` above.
            self?.finish(outcome, mappingSkips: mappingSkips, url: url)
        }
    }

    // MARK: - Folder exports (static site 014 · S3, originals 011 · A2)

    /// Write a folder off the main actor, streaming one file at a time.
    ///
    /// The shape both folder exports share, so neither owns a private copy of the
    /// cleanup rule or the cancel rule:
    ///
    ///  • **cleanup** — a destination this run CREATED is removed if the run does
    ///    not finish; a pre-existing one is the user's and is left alone, because a
    ///    cancelled export must not delete a folder someone already had;
    ///  • **cancel** — the FLAG is asked before the error, never the other way
    ///    round (301). Work already in flight throws on the way out of a cancel, and
    ///    a user who pressed Stop must not be told their export failed.
    ///
    /// `write` returns its per-file skips; the caller supplies the mapping skips
    /// that never reached a file at all.
    private func runFolderJob(
        mappingSkips: Int,
        to url: URL,
        write: @escaping @Sendable (
            _ isCancelled: @Sendable () -> Bool, _ onProgress: @Sendable (Double) -> Void
        ) throws -> [ExportSkip]
    ) {
        let flag = beginRun()
        let onProgress = progressSink()

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                let preexisting = FileManager.default.fileExists(atPath: url.path)
                do {
                    let skips = try write({ flag.isCancelled }, onProgress)
                    return .done(SkipBreakdown(
                        fileSkips: skips, notExportable: mappingSkips))
                } catch {
                    if !preexisting { try? FileManager.default.removeItem(at: url) }
                    if flag.isCancelled || error is CancellationError { return .cancelled }
                    return .failed(error.localizedDescription)
                }
            }.value

            // No `await`: this `Task` inherits the enclosing `@MainActor`, and
            // `finish` is a synchronous method on it, so there was never a
            // suspension here to mark. The hop already happened at `.value` above.
            self?.finish(outcome, mappingSkips: mappingSkips, url: url)
        }
    }

    /// Write the plan's web-page folder.
    ///
    /// `internal` rather than `private` so `ExportControllerTests` can drive a run
    /// against a temp directory without an `NSSavePanel` (the destination is already
    /// an explicit argument). Not part of the surface any view uses —
    /// `requestSiteExport` is.
    func startSite(plan: CollectionSiteExport.Plan, to url: URL) {
        let gallery = plan.gallery
        let assets = plan.assets
        runFolderJob(mappingSkips: plan.skipped, to: url) { isCancelled, onProgress in
            // No `createDirectory` here: the writer creates `<root>/assets` with
            // intermediates, which creates the root too.
            try SiteExportWriter.write(
                gallery: gallery, assets: assets, to: url,
                isCancelled: isCancelled, onProgress: onProgress).skipped
        }
    }

    /// Copy the plan's originals into the folder.
    ///
    /// `internal` for the reason ``startSite(plan:to:)`` gives — panel-free testing.
    func startAssets(plan: AssetFolderExport.Plan, to url: URL) {
        let files = plan.files
        runFolderJob(mappingSkips: plan.skipped, to: url) { isCancelled, onProgress in
            try AssetFolderWriter.write(
                files: files, to: url,
                isCancelled: isCancelled, onProgress: onProgress).skipped
        }
    }

    // MARK: - Run lifecycle

    /// Mark a run as started and hand back its cancel flag.
    private func beginRun() -> CancelFlag {
        isExporting = true
        progress = 0
        let flag = CancelFlag()
        cancelFlag = flag
        return flag
    }

    /// The main-actor outcome tail, shared by all three start paths (see the file
    /// note). `.success` is PROMOTED to `.incomplete` here, in one place, whenever
    /// anything was left out — so no export path can forget to.
    private func finish(_ outcome: Outcome, mappingSkips: Int, url: URL) {
        switch outcome {
        case .done(let skipped):
            publish(skipped.isEmpty ? .success : .incomplete, skipped: skipped, url: url)
        case .cancelled:
            publish(.cancelled, skipped: SkipBreakdown())
        case .failed(let message):
            publish(.failed(message), skipped: SkipBreakdown(notExportable: mappingSkips))
        }
    }

    /// End the run and report. Resets `isExporting` / `cancelFlag` / `task`, so it
    /// is ONLY for a terminal outcome — see ``report(_:skipped:)`` for a refusal,
    /// which must not tear down the run it is declining to interrupt.
    private func publish(
        _ outcome: Report.Outcome, skipped: SkipBreakdown, url: URL? = nil
    ) {
        isExporting = false
        cancelFlag = nil
        task = nil
        if case .success = outcome { progress = 1 }
        if case .incomplete = outcome { progress = 1 }
        report(outcome, skipped: skipped, url: url)
    }

    /// Stamp and publish a report WITHOUT touching run state.
    ///
    /// Split from ``publish(_:skipped:url:)`` because of the refusal case: a second
    /// export request arriving mid-run has to report that it was declined, and if
    /// that report reset `isExporting` / `cancelFlag` / `task` it would orphan the
    /// run actually in flight — the ring would stop, Stop would no longer cancel,
    /// and the real export would finish invisibly.
    private func report(
        _ outcome: Report.Outcome, skipped: SkipBreakdown, url: URL? = nil
    ) {
        reportSeq += 1
        lastReport = Report(outcome: outcome, skipped: skipped, url: url, seq: reportSeq)
    }

    /// Whether a request must be declined because a run is in flight — and say so
    /// rather than returning silently (011 · A2 review).
    ///
    /// The four entry points are reachable from the selection popover, the File
    /// menu, two right-click menus and a board button. The SwiftUI rows disable
    /// themselves off `isExporting`, but a menu command cannot as cheaply, so those
    /// paths used to click and do nothing at all — the least debuggable failure
    /// there is. One report here covers every path, present and future.
    private func refuseIfBusy() -> Bool {
        guard isExporting else { return false }
        report(.failed("An export is already running"), skipped: SkipBreakdown())
        return true
    }

    /// A progress sink that only publishes when the bar would visibly move.
    ///
    /// The writers call `onProgress` once per FILE, and a folder export's file count
    /// is unbounded — the File-menu path exports a whole collection. Unthrottled,
    /// 5,000 files meant 5,000 `Task` allocations and 5,000 `@Published`
    /// invalidations for a ring with perhaps a hundred distinguishable states. The
    /// final `1` is always let through, so the ring completes.
    private func progressSink() -> @Sendable (Double) -> Void {
        let gate = ProgressGate()
        return { [weak self] fraction in
            guard let self, gate.shouldPublish(fraction) else { return }
            Task { @MainActor in self.progress = fraction }
        }
    }

    /// The off-main work's result, kept `Sendable` for the detached hop.
    private enum Outcome: Sendable {
        case done(SkipBreakdown)
        case cancelled
        case failed(String)
    }
}

/// A minimal thread-safe cancel flag. `Task.detached` does not inherit the
/// parent's cancellation, so the render reads this instead of `Task.isCancelled`.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

/// Thresholds progress ticks so a long export does not flood the main actor.
/// `CancelFlag`'s shape and for the same reason: the writer calls it from a
/// detached task, so the state it guards needs a lock rather than an actor.
nonisolated final class ProgressGate: @unchecked Sendable {
    /// Publish when the fraction has moved at least this much since the last one.
    static let step = 0.01

    private let lock = NSLock()
    private var last = -1.0

    /// Whether `fraction` should reach the UI. Always true at completion (`>= 1`),
    /// so the ring is never left short of full by the threshold — and always true
    /// for the FIRST tick (`last` starts below zero), so the ring starts moving as
    /// soon as there is anything to show rather than after the first whole percent.
    func shouldPublish(_ fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fraction >= 1 || fraction - last >= Self.step else { return false }
        last = fraction
        return true
    }
}
