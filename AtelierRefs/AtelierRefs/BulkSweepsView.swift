//
//  BulkSweepsView.swift
//  AtelierRefs
//
//  015 · Phase 7 — the bulk-import ("sweep") tab. Two states over one shared
//  ``IngestionModel``:
//    · BEFORE consent — a disclosure panel (own-data-only, human-paced,
//      ToS/account-risk) whose acceptance persists the flag the server's `/jobs`
//      open gate reads. Until then, the extension can't start a sweep.
//    · AFTER consent — a live, ledger-driven progress list (ingested / skipped /
//      failed / estimate) with pause / resume / cancel. A sweep runs in the
//      browser, so the view POLLS the ledger; the controls transition the job's
//      status, which the running loop honours on its next item (7A relay feedback).
//

import AtelierCore
import SwiftUI

struct BulkSweepsView: View {
    @ObservedObject var model: IngestionModel

    @State private var confirmingTurnOff = false

    var body: some View {
        Group {
            if model.bulkConsentGranted {
                sweepsList
            } else {
                ConsentPanel(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A sweep lands rows out of band (from the browser), so poll while visible.
        .task {
            while !Task.isCancelled {
                await model.refreshSweeps()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var sweepsList: some View {
        if model.sweeps.isEmpty {
            ContentUnavailableView(
                "No sweeps yet",
                systemImage: "square.stack.3d.up",
                description: Text("Start a bulk import from the extension on a "
                    + "Pinterest board or your X bookmarks. Its progress shows here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.sweeps) { sweep in
                        SweepRow(sweep: sweep, model: model)
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem {
                    Button("Turn Off Bulk Import") { confirmingTurnOff = true }
                }
            }
            .confirmationDialog(
                "Turn off bulk import?",
                isPresented: $confirmingTurnOff,
                titleVisibility: .visible
            ) {
                // Return commits, as in every confirmation dialog here — a
                // `role: .destructive` button is left unbound otherwise (see
                // ``ContentView``'s delete dialog for the mechanism).
                Button("Turn Off", role: .destructive) { model.revokeBulkConsent() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The extension can't start new sweeps until you re-enable it. "
                     + "Items already imported stay in your library.")
            }
        }
    }
}

// MARK: - Consent

private struct ConsentPanel: View {
    @ObservedObject var model: IngestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Bulk import", systemImage: "square.and.arrow.down.on.square")
                .font(Theme.Typography.pageTitle)

            Text("Bulk import sweeps **your own** saved items — a Pinterest board "
                 + "you own, or your X bookmarks — from a session you're already "
                 + "logged into, and saves them here with their provenance.")

            VStack(alignment: .leading, spacing: 8) {
                bullet("It only ever touches your own logged-in data — never anyone "
                       + "else's account or private content.")
                bullet("It runs at a human pace and can be throttled by the platform. "
                       + "A sweep may pause; you can resume it later.")
                bullet("Automated access can be against a platform's Terms of Service "
                       + "and carries some account risk. You accept that risk.")
                bullet("Nothing leaves your Mac — items are fetched in your browser "
                       + "and saved to your local library.")
                bullet("Re-sweeps skip what you already have. Deleting a saved item "
                       + "forgets it, so a later sweep can import it again.")
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.inkSecondary)

            // `DialogButtonStyle(width: .fill)` is the app's primary-action idiom — the
            // full-width outlined button every export popover ends with.
            // `.borderedProminent` drew this accent-filled, which put the app's loudest
            // coloured control on the one screen whose job is to be read carefully
            // before it is agreed to.
            Button {
                model.grantBulkConsent()
            } label: {
                Text("I understand — enable bulk import")
            }
            .buttonStyle(DialogButtonStyle())
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 520)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 5)
            Text(text)
        }
    }
}

// MARK: - Sweep row

private struct SweepRow: View {
    let sweep: IngestionModel.SweepProgress
    @ObservedObject var model: IngestionModel

    @State private var confirmingCancel = false
    @State private var showFailures = false
    @State private var failures: [JobItem] = []
    @State private var loadingFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Theme.Typography.bodyEmphasis)
                Spacer()
                StatusBadge(status: sweep.job.status)
            }

            // Tinted: a `ProgressView` draws in the system ACCENT by default, which is
            // the user's chosen highlight colour (blue out of the box) and therefore
            // the one piece of chrome the app can't predict. `inkSecondary` keeps the
            // bar readable without introducing a colour the theme doesn't own.
            if let fraction = sweep.fraction {
                ProgressView(value: fraction).tint(Theme.Colors.inkSecondary)
            } else if sweep.job.status == .open {
                // Indeterminate — no estimate yet.
                ProgressView().controlSize(.small).tint(Theme.Colors.inkSecondary)
            }

            HStack(spacing: 14) {
                stat("Saved", sweep.ingested, "tray.and.arrow.down")
                stat("Skipped", sweep.skipped, "arrow.uturn.forward")
                if sweep.failed > 0 { stat("Failed", sweep.failed, "exclamationmark.triangle") }
                if let total = sweep.total { Text("of \(total)").foregroundStyle(.secondary) }
                Spacer()
                controls
            }
            .font(Theme.Typography.body)

            if sweep.failed > 0 { failuresSection }
        }
        // `surface` on a `hairline`, the app's raised-card recipe — this was
        // `.quaternary.opacity(0.4)`, a system material that samples what is behind it
        // rather than sitting on the palette.
        .padding(Theme.Spacing.lg)
        .background(
            Theme.Colors.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.hairline))
        .confirmationDialog(
            "Cancel this sweep?",
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel Sweep", role: .destructive) { model.cancelSweep(sweep.id) }
                .keyboardShortcut(.defaultAction)
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("The import stops where it is and can't be resumed. Items already "
                 + "saved stay in your library; a later sweep re-imports the rest.")
        }
    }

    private var title: String {
        let platform = sweep.job.platform.rawValue.capitalized
        if let scope = sweep.job.scope, !scope.isEmpty { return "\(platform) — \(scope)" }
        return platform
    }

    private func stat(_ label: String, _ value: Int, _ symbol: String) -> some View {
        Label("\(value) \(label.lowercased())", systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var controls: some View {
        switch sweep.job.status {
        case .open:
            Button("Pause") { model.pauseSweep(sweep.id) }
            Button("Cancel", role: .destructive) { confirmingCancel = true }
        case .paused:
            Button("Resume") { model.resumeSweep(sweep.id) }
            Button("Cancel", role: .destructive) { confirmingCancel = true }
        case .complete, .halted:
            // A terminal sweep with recoverable failures can be re-run (034 P2):
            // re-opening re-attempts everything not yet ingested.
            if sweep.retryableFailed > 0 {
                Button("Retry Failed") { model.retrySweep(sweep.id) }
            }
        }
    }

    /// An expandable breakdown of the failures — the "Failed N" count used to be a
    /// dead-end (034 P2). Shows the temporary/permanent split, then the failed items
    /// (with their source URL) on demand.
    @ViewBuilder
    private var failuresSection: some View {
        DisclosureGroup(isExpanded: $showFailures) {
            VStack(alignment: .leading, spacing: 6) {
                if loadingFailures {
                    ProgressView().controlSize(.small)
                } else if failures.isEmpty {
                    Text("No item details recorded for these failures.")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(failures, id: \.sourceID) { item in
                        failureRow(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(failureSummary).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: showFailures) {
            guard showFailures, failures.isEmpty, !loadingFailures else { return }
            loadingFailures = true
            failures = await model.sweepFailures(jobID: sweep.id)
            loadingFailures = false
        }
    }

    private var failureSummary: String {
        var parts: [String] = []
        if sweep.retryableFailed > 0 { parts.append("\(sweep.retryableFailed) temporary") }
        if sweep.permanentFailed > 0 { parts.append("\(sweep.permanentFailed) permanent") }
        return parts.isEmpty ? "Failure details" : parts.joined(separator: " · ")
    }

    private func failureRow(_ item: JobItem) -> some View {
        HStack(spacing: 8) {
            // The temporary/permanent split keeps its two colours: unlike the status
            // badge, these two sit on the SAME row at the same time, and the
            // distinction between "retry fixes this" and "retry won't" is exactly what
            // the row exists to convey. The orange half moves onto the token.
            Image(systemName: item.status == .retryableFailed
                  ? "clock.arrow.circlepath" : "xmark.octagon")
                .foregroundStyle(item.status == .retryableFailed ? Theme.Colors.warning : .red)
                .help(item.status == .retryableFailed
                      ? "Temporary — retry can recover this" : "Permanent — retry won't help")
            if let url = item.sourceURL, !url.isEmpty {
                Button {
                    model.openSourceURL(url)
                } label: {
                    Text(url).lineLimit(1).truncationMode(.middle)
                }
                // `.link` renders in the system accent (blue). The underline and the
                // pointer cursor still say "link" without the colour.
                .buttonStyle(.link)
                .tint(Theme.Colors.inkPrimary)
            } else {
                Text(item.sourceID).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.caption)
    }
}

/// A sweep's state as a capsule.
///
/// MONOCHROME except for Stopped. This was a four-colour scale (green / orange / blue
/// / grey) — the most colour-coded thing in the app, in a theme whose one rule is that
/// there is no accent. Running, Paused and Complete are all ordinary states of a job
/// that is behaving, so they wear the app's `field` capsule and differ by their WORD;
/// only `.halted` — a sweep that stopped without finishing — earns
/// ``Theme/Colors/warning``, which is the same signal the endpoint dot and every
/// warning label in Settings use.
private struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(label).font(Theme.Typography.caption).bold()
            .padding(.horizontal, Theme.Spacing.sm).padding(.vertical, 3)
            .background(Theme.Colors.field, in: Capsule())
            .foregroundStyle(isProblem ? Theme.Colors.warning : Theme.Colors.inkSecondary)
    }

    private var label: String {
        switch status {
        case .open: return "Running"
        case .paused: return "Paused"
        case .complete: return "Complete"
        case .halted: return "Stopped"
        }
    }

    /// Only a sweep that stopped short is a problem. A PAUSED one was paused on
    /// purpose (by the user, or by the platform throttling it) and resumes — colouring
    /// it would cry wolf on the app's single alarm colour.
    private var isProblem: Bool { status == .halted }
}
