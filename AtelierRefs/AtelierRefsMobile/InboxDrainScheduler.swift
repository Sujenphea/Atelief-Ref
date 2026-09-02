// AtelierRefsMobile — the SwiftUI half of the drain cadence, and only that
// (096 · 4, phase 4).
//
// Everything this file used to hold — `inFlight`, `exportsHolding`, `missedActivation`,
// `hasStarted`, the coalescing rule, the deferred activation and `exclusively(_:)` — now
// lives in `AtelierBrowse/InboxDrainPolicy.swift`, where `swift test` can reach it. Phase
// 3 shipped that policy with no test at all and said so in its own changelog; the argument
// for where it went is in the new file's header and in `.change-log/455`.
//
// What is left here is what genuinely could not go: SwiftUI's `ScenePhase`, the app's
// `Logger`, and the mapping from a `DrainSummary` to those two. The policy imports
// Foundation and nothing else, which is the property that makes it testable on the host;
// spelling `ScenePhase` inside it would have cost exactly that.
//
// The name `InboxDrainScheduler` is kept — as the concrete spelling of the policy for this
// app — because it is the name the Mac's equivalent has, the name `ContentView` and
// `CaptureExport` were written against, and because "the scheduler" is what the phone's
// header comments have called this thing since phase 3.

import AtelierBrowse
import AtelierIngestion
import Foundation
import os
import SwiftUI

/// The drain policy as this app instantiates it: a pass returns a ``DrainSummary``.
///
/// A typealias rather than a subclass or a wrapper. There is nothing to add — the app's
/// two contributions are the phase mapping and the report, and both are below as
/// extensions, so an object in between would exist only to forward five methods.
typealias InboxDrainScheduler = InboxDrainPolicy<DrainSummary>

// MARK: - The SwiftUI adapter

extension ScenePhaseKind {
    /// SwiftUI's phase, as the policy's.
    ///
    /// The whole reason this file still exists. `ScenePhase` is a SwiftUI type; the policy
    /// deliberately imports Foundation only, so the one place the two vocabularies meet is
    /// here, in the target that already has SwiftUI linked.
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        // A phase this app has never seen is deliberately NOT `.active`: the rule is
        // "drain on active, and only active", and a case added by a future SDK that this
        // build maps to the one value that starts work would be a drain fired by something
        // nobody here has reasoned about.
        @unknown default: self = .inactive
        }
    }
}

extension InboxDrainPolicy {
    /// The scene changed phase; drain if it just became active.
    ///
    /// An overload rather than a rename, so the call site in `ContentView` reads exactly as
    /// it did when the whole type was in this target.
    func scenePhaseChanged(to phase: ScenePhase) {
        scenePhaseChanged(to: ScenePhaseKind(phase))
    }
}

// MARK: - The result

extension InboxDrainPolicy where Outcome == DrainSummary {

    /// Build the phone's scheduler: a pass, and what the app does with what it found.
    ///
    /// The `onIngest:` spelling is kept from phase 3 rather than exposing the policy's
    /// `report:` here, because the app has exactly one thing to do with a summary that is
    /// not a log line, and naming the callback for that thing is what makes the call site
    /// in `ContentView` say what it means.
    convenience init(
        pass: @escaping @MainActor () async -> DrainSummary,
        onIngest: @escaping @MainActor () -> Void,
        onNotice: @escaping @MainActor (String?) -> Void
    ) {
        self.init(
            pass: pass,
            report: { summary in
                InboxDrainScheduler.report(
                    summary, onIngest: onIngest, onNotice: onNotice)
            },
            observe: { event in InboxDrainScheduler.log(event) })
    }

    /// The two `.debug` lines phase 3 wrote from inside the scheduler, now written from
    /// outside it. Same text, same level, same reason: an activation that did not become a
    /// pass is invisible in every other record of what the app did, and the first question
    /// asked of a phone that "did not import my share" is which of these two happened.
    static func log(_ event: InboxDrainEvent) {
        switch event {
        case .activationDroppedDuringPass:
            MobileLog.capture.debug("inbox drain already running; activation pass skipped")
        case .activationDeferredDuringExport:
            MobileLog.capture.debug("inbox held by an export; activation pass deferred")
        }
    }

    /// Log what the pass found, and tell the app if the library changed.
    ///
    /// **The log is not the only reader any more** (098 · P6). This used to say that
    /// nothing here reaches the user, on the ground that an unreadable inbox and a
    /// quarantined capture are conditions a person has no lever for. Both are still true
    /// and 093 § 1 had already named the exception, in the paragraph defending the word
    /// "Saved" on the share sheet's card: a quarantine "is a bug and belongs on the surface
    /// that can show it". `DrainSummary.userNotice` decides which of the six fields is
    /// worth a sentence — two of them — and this routes it. The rule it applies is not "can
    /// the user act" but "would the app otherwise misrepresent itself"; the argument is at
    /// the property.
    ///
    /// This is the half of phase 3's `report(_:)` that could not move: `os.Logger` is the
    /// app's, and the counter it bumps belongs to `LibraryStore`. The half that DID move is
    /// the guarantee this is called under — once per completed pass, after the inbox has
    /// been released — which is now pinned by `InboxDrainPolicyTests`.
    ///
    /// **And the WORDING moved too** (098 · finding 5). Until now the body below was
    /// byte-identical to `AtelierRefs/InboxDrainScheduler.swift`'s apart from the logger
    /// name — including in what it left out, which was `skippedExhausted`: the fate phase 2
    /// added for exactly this platform, produced only under `.retainForExport`, and named
    /// in neither app's log. ``DrainSummary/reportLines`` decides the sentences, their
    /// order and their level; what is left here is the mapping onto `MobileLog`, which is
    /// the app's and cannot be anything else.
    static func report(
        _ summary: DrainSummary,
        onIngest: @MainActor () -> Void,
        onNotice: @MainActor (String?) -> Void
    ) {
        for line in summary.reportLines {
            switch line.level {
            case .notice: MobileLog.capture.notice("\(line.text, privacy: .public)")
            case .error: MobileLog.capture.error("\(line.text, privacy: .public)")
            }
        }
        if summary.ingested > 0 { onIngest() }
        // Unconditional, `nil` included: a pass with nothing to say must clear a notice an
        // earlier pass put up, or a quarantine reported once stays on screen for the life
        // of the process. The phone drains on every activation, so a condition that still
        // holds says so again within seconds.
        onNotice(summary.userNotice)
    }
}
