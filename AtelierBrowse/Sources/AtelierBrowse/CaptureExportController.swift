// AtelierBrowse — the phase machine behind the send control (092 · S6b, 096 · 3B,
// moved here by 098 · P3).
//
// `.idle → .working → .ready(folder) → .sent(n) → .idle`, plus `.failed(sentence)`, plus
// the two answers to the offer that `.sent` is. That is five states, seven transitions
// and one invariant that matters more than any of them — **the ids a "Clear" may retire
// are the ids that actually reached the last manifest, and nothing else** — and until
// this move none of it was reachable by a test. 098 · finding 9 counted the cost:
// "`CaptureExport` and `LibraryStore` import no UIKit, yet the export phase machine, the
// count semantics [and] the bootstrap failure mapping have no test."
//
// **What was left in the app, and it is I/O.** Reading the inbox, writing the archive and
// retiring records are three closures here. That is not a purity exercise: `InboxArchive`
// lives in `AtelierArchive`, which this package deliberately does not link (the same
// argument `InboxDrainPolicy` makes about `DrainSummary` — a package that types one
// closure's return value has linked a whole subsystem to do it). Injecting them buys the
// tests a fake inbox that can be empty, unreadable, or slow on demand, which is the
// only way the interesting states are reachable at all. `UIActivityViewController` and
// the share sheet stay in the app, where UIKit is.
//
// The rest of the argument — why an export takes the inbox exclusively, why nothing is
// deleted after a send, why the offer to clear is an offer — is at each member below and
// in `AtelierRefsMobile/CaptureExport.swift`, which is now the wiring.

import Foundation
import Observation

/// What an export can fail with, in the vocabulary the phone words sentences from.
///
/// Two cases, because two failures are worth telling apart on a screen: there was
/// nothing to send, and there was something to send and none of it could be read. Every
/// other failure — a full disk, a directory that will not create — is the third sentence
/// and is not a case, because naming it would promise a distinction the app cannot draw.
/// The app's write closure maps `InboxArchive.WriteError` onto these.
public enum CaptureExportFailure: Error, Equatable {
    /// The pending set was empty when the archive was written.
    case nothingToExport
    /// Records were waiting and not one of their payloads could be copied.
    case nothingCopied
}

@MainActor
@Observable
public final class CaptureExportController {
    public enum Phase: Equatable {
        case idle
        case working
        /// The archive is written; `url` is the folder to hand to a share sheet.
        case ready(URL)
        /// The share sheet has been dismissed and there are captures the user could now
        /// retire (096 · 3B). `count` is how many actually reached the manifest — not how
        /// many were pending, which is a superset.
        case sent(Int)
        case failed(String)
    }

    /// Where an export landed, and which captures are in it.
    public struct Written: Sendable, Equatable {
        public let url: URL
        public let exported: [UUID]

        public init(url: URL, exported: [UUID]) {
            self.url = url
            self.exported = exported
        }
    }

    /// How many captures are owed to the Mac — `InboxArchive.pending(in:).records.count`
    /// in the app, and throwing because reading a directory is.
    ///
    /// All three seams below are `@MainActor`, like ``InboxWork``: this controller is a
    /// UI object and every one of them is called from a place the UI already is. Hopping
    /// off for the actual filesystem work is the APP's decision and the app makes it —
    /// see `AtelierRefsMobile/CaptureExport.swift`, where each of these wraps a
    /// `Task.detached`. Spelling `@Sendable` here instead would have moved that decision
    /// into the package and made the tests build a box to get back out of it.
    public typealias PendingCount = @MainActor () throws -> Int

    /// Write the archive into `folderName` under `parent`, stamped `now`. Async because
    /// the app runs it off the main actor; throwing ``CaptureExportFailure`` where it can
    /// say which failure it was.
    public typealias Write = @MainActor (
        _ parent: URL, _ folderName: String, _ now: Date
    ) async throws -> Written

    /// Retire the ids the user has asserted their Mac has. Cannot fail in a way the phone
    /// has anything to say about — a record that will not move stays where it is and is
    /// simply sent again, and re-import collapses on blob hash (091 · D4).
    public typealias Retire = @MainActor ([UUID]) async -> Void

    public private(set) var phase: Phase = .idle

    /// Pending captures on this device, or `nil` before the first count.
    ///
    /// Drives whether the export control is shown at all: an empty inbox has nothing to
    /// offer, and a button that always says "0" is chrome apologising for itself.
    public private(set) var pending: Int?

    /// The ids that reached the last export's manifest, and therefore the only ones the
    /// clear control may retire.
    ///
    /// **Not "everything pending".** `InboxArchive` skips records its funnel refuses, and a
    /// share made while the share sheet was open was never in the export at all. Retiring
    /// either would take a capture out of the pending set on the strength of a send it was
    /// not in — which is how "nothing is lost" quietly stops being true.
    private var exported: [UUID] = []

    /// Where export folders go. Injectable so a test can watch a real directory rather
    /// than the process's own caches, and because the one thing every export shares is
    /// that exactly one folder survives under it.
    private let exportsParent: URL

    /// Takes the inbox away from the drain for the duration of a body (096 · 4).
    ///
    /// **No default**, for the same reason `InboxDrain.Retention` has none: a default would
    /// be a decision about who else is writing this directory, taken silently on behalf of
    /// every future caller, and the caller that gets it wrong loses a payload mid-copy
    /// rather than failing a build.
    private let exclusion: InboxExclusion
    private let pendingCount: PendingCount
    private let write: Write
    private let retireIDs: Retire

    public init(
        exportsParent: URL,
        exclusion: @escaping InboxExclusion,
        pendingCount: @escaping PendingCount,
        write: @escaping Write,
        retire: @escaping Retire
    ) {
        self.exportsParent = exportsParent
        self.exclusion = exclusion
        self.pendingCount = pendingCount
        self.write = write
        self.retireIDs = retire
    }

    /// Re-count what is waiting to be sent, and safe to call on every appearance —
    /// which is what keeps the control honest after a share.
    ///
    /// **A count that throws becomes zero, and zero hides the control.** That is the
    /// behaviour this move inherited and it is pinned by a test rather than fixed here:
    /// showing "the inbox could not be read" is a screen, and screens are 098 · P6's. What
    /// the pin buys is that the next person to change it has to change a test that says
    /// out loud what today's app does — a phone whose inbox directory cannot be
    /// enumerated offers no way to send the captures sitting in it.
    public func refresh() {
        pending = (try? pendingCount()) ?? 0
    }

    /// Write the archive, with the inbox to ourselves.
    ///
    /// `.working` is set BEFORE the wait rather than after it: the send button disables on
    /// that phase, and a control that stays live while an export queues behind a drain pass
    /// is a control that can be pressed twice.
    public func export(now: Date = Date()) async {
        phase = .working
        await exclusion { [weak self] in
            guard let self else { return }
            await runExport(now: now)
        }
    }

    /// The archive write itself, once the inbox is ours.
    private func runExport(now: Date) async {
        do {
            let written = try await write(exportsParent, Self.folderName(now), now)
            exported = written.exported
            phase = .ready(written.url)
        } catch {
            // The ids from a previous export are dropped on a failure, deliberately: a
            // "Clear" offered after a failed send would retire captures on the strength of
            // a transfer that did not happen.
            exported = []
            phase = .failed(Self.message(for: error))
        }
        refresh()
    }

    /// Dismissing the share sheet leaves the folder in Caches for the system to reclaim,
    /// and — if anything actually went into it — offers to retire what was sent.
    ///
    /// **The offer is here rather than on the send button, because this is the first moment
    /// the phone knows anything happened.** `UIActivityViewController`'s completion cannot
    /// tell us whether the AirDrop landed or the user cancelled, and the Mac says nothing
    /// back (091 · D4 — no second transport direction). So the app does not infer; it asks,
    /// once, at the point where the user has just watched the transfer and is the only
    /// party who knows.
    public func finish() {
        phase = exported.isEmpty ? .idle : .sent(exported.count)
    }

    /// Retire the last export's captures — the user asserting the Mac has them (096 · 3B).
    ///
    /// Under the same exclusion the export runs under, and for a sharper version of the
    /// same reason: this MOVES and DELETES records the drain may be reading in the middle
    /// of a pass.
    ///
    /// **Only `exported`.** Never "everything pending" — see the property's own note. An
    /// empty set is not an error and not a no-op either: it returns the controller to
    /// `.idle`, which is what a `.failed` notice's timeout and a cancelled share both need.
    public func retire() async {
        let ids = exported
        guard !ids.isEmpty else {
            phase = .idle
            return
        }
        await exclusion { [weak self] in
            guard let self else { return }
            await retireIDs(ids)
            exported = []
            phase = .idle
            refresh()
        }
    }

    /// Decline the offer: the captures stay pending and will go out again next time. The
    /// safe answer, and the one a user picks when they are not sure the transfer worked.
    public func keep() {
        exported = []
        phase = .idle
    }

    // MARK: - Wording

    /// `Atelier 2026-08-17 1830` — sortable, and it says what it is on a Mac desktop where
    /// it will sit beside whatever else was AirDropped that day.
    ///
    /// Locale-independent on purpose (`en_US_POSIX`): the folder name crosses to another
    /// machine and is read by a person, and a phone set to a calendar this code has never
    /// seen must not produce a name that does not sort.
    public static func folderName(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Atelier \(formatter.string(from: now))"
    }

    /// What a failed export says. Three sentences, and the third is everything else —
    /// see ``CaptureExportFailure``.
    public static func message(for error: Error) -> String {
        switch error {
        case CaptureExportFailure.nothingToExport:
            "There are no captures waiting to be sent."
        case CaptureExportFailure.nothingCopied:
            "None of the waiting captures could be read."
        default:
            "The captures couldn't be written."
        }
    }
}
