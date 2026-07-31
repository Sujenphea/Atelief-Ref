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
