//
//  ExportController.swift
//  AtelierRefs
//
//  052 · B3 — the window-level export orchestrator. Owns the save panel, runs
//  the render OFF the main actor (052 · 15A), publishes progress for the top-bar
//  ring, and reports the outcome (success / cancelled / failed + skip count) for
//  the `ToastCenter` summary (052 · 7A). One instance per window, injected as an
//  `EnvironmentObject` so both the Space board's Export button and the top-bar
//  progress icon observe the same state.
//

import AppKit
import AtelierExport
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ExportController: ObservableObject {

    /// The terminal outcome of an export, surfaced as a toast.
    struct Report: Equatable {
        enum Outcome: Equatable {
            case success
            case cancelled
            case failed(String)
        }
        var outcome: Outcome
        /// Rows that couldn't be drawn (media-less mapping skips + render misses).
        var skipped: Int
        /// Where it was written (success only).
        var url: URL?
        /// Monotonic — trips `.onChange` even for identical back-to-back reports.
        var seq: Int
    }

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastReport: Report?

    private var task: Task<Void, Never>?
    private var cancelFlag: CancelFlag?
    private var reportSeq = 0

    // MARK: - Entry point

    /// Present the save panel for `config`, then export `mapping` to the chosen
    /// destination. No-op while an export is already running, or when there is
    /// nothing renderable.
    func requestExport(
        mapping: MoodboardExport.Mapping,
        config: ExportConfig,
        suggestedName: String
    ) {
        guard !isExporting else { return }
        guard !mapping.isEmpty else {
            publish(Report(outcome: .failed("Nothing to export"), skipped: mapping.skipped, url: nil, seq: 0))
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

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    /// Present the save panel for a static-site export (014 · S3), then write
    /// `plan` into the chosen folder. No-op while an export is already running,
    /// and refused outright for an empty plan — an empty collection disables the
    /// action rather than producing an empty folder.
    ///
    /// A second entry point on the SAME controller rather than a second
    /// controller: the progress ring, the cancel popover and the completion
    /// toast all observe `isExporting` / `progress` / `lastReport`, and a third
    /// export that behaved differently from the first two would be a third thing
    /// for the user to learn for no benefit.
    func requestSiteExport(plan: CollectionSiteExport.Plan, suggestedName: String) {
        guard !isExporting else { return }
        guard !plan.isEmpty else {
            publish(Report(
                outcome: .failed("Nothing to export"), skipped: plan.skipped, url: nil, seq: 0))
            return
        }

        // A save panel, not an open panel: the user is naming something new. The
        // "file" it names is the folder this writes `index.html` and `assets/`
        // into, so there is no content type and no extension.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to write the web page folder "
            + "(index.html + assets)."

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startSite(plan: plan, to: url)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    /// Cancel a running export (from the top-bar popover). Sets the render's
    /// cancel flag and tears down the wrapping task.
    func cancel() {
        cancelFlag?.cancel()
        task?.cancel()
    }

    // MARK: - Render

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
            publish(Report(outcome: .failed("Nothing to export"), skipped: mappingSkips, url: nil, seq: 0))
            return
        }

        isExporting = true
        progress = 0
        let flag = CancelFlag()
        cancelFlag = flag

        // Forward render progress back to the main actor for the ring.
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.progress = fraction }
        }

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> RenderOutcome in
                do {
                    let result = try MoodboardExport.render(
                        pages: pages, provider: provider, config: config,
                        background: background,
                        isCancelled: { flag.isCancelled }, onProgress: onProgress)
                    try result.data.write(to: url, options: .atomic)
                    return .done(skipped: result.skipped.count)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value

            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .done(let renderSkips):
                    self.publish(Report(
                        outcome: .success, skipped: mappingSkips + renderSkips,
                        url: url, seq: 0))
                case .cancelled:
                    self.publish(Report(outcome: .cancelled, skipped: 0, url: nil, seq: 0))
                case .failed(let message):
                    self.publish(Report(
                        outcome: .failed(message), skipped: mappingSkips, url: nil, seq: 0))
                }
            }
        }
    }

    // MARK: - Static site (014 · S3)

    /// Write the plan's folder off the main actor, streaming one file at a time.
    private func startSite(plan: CollectionSiteExport.Plan, to url: URL) {
        isExporting = true
        progress = 0
        let flag = CancelFlag()
        cancelFlag = flag

        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.progress = fraction }
        }

        let gallery = plan.gallery
        let assets = plan.assets
        let mappingSkips = plan.skipped

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> RenderOutcome in
                // Only clean up a folder this run created; a pre-existing one is
                // the user's, and a cancelled export must not delete it.
                let preexisting = FileManager.default.fileExists(atPath: url.path)
                do {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true)
                    let result = try SiteExportWriter.write(
                        gallery: gallery, assets: assets, to: url,
                        isCancelled: { flag.isCancelled }, onProgress: onProgress)
                    return .done(skipped: result.skipped.count)
                } catch {
                    if !preexisting { try? FileManager.default.removeItem(at: url) }
                    // Ask the FLAG first, never the error (301): work already in
                    // flight throws on the way out of a cancel, and a user who
                    // pressed Stop must not be told their export failed.
                    if flag.isCancelled || error is CancellationError { return .cancelled }
                    return .failed(error.localizedDescription)
                }
            }.value

            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .done(let writeSkips):
                    self.publish(Report(
                        outcome: .success, skipped: mappingSkips + writeSkips,
                        url: url, seq: 0))
                case .cancelled:
                    self.publish(Report(outcome: .cancelled, skipped: 0, url: nil, seq: 0))
                case .failed(let message):
                    self.publish(Report(
                        outcome: .failed(message), skipped: mappingSkips, url: nil, seq: 0))
                }
            }
        }
    }

    /// Finalise state + stamp the report's monotonic sequence.
    private func publish(_ report: Report) {
        isExporting = false
        cancelFlag = nil
        task = nil
        reportSeq += 1
        var stamped = report
        stamped.seq = reportSeq
        if case .success = report.outcome { progress = 1 }
        lastReport = stamped
    }

    /// The off-main render's result, kept `Sendable` for the detached hop.
    private enum RenderOutcome: Sendable {
        case done(skipped: Int)
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
