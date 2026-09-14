//
//  VideoPosterGate.swift
//  AtelierRefs
//
//  The rule that decides when the detail page's video poster comes DOWN.
//
//  `ItemDetailView` draws the 1280 poster on top of the `VideoPlayer` until a frame
//  can exist (the ZStack in `mediaArea`, and `.change-log/383` for why on top and
//  not behind). The poster is opaque, so the rule that lifts it is the difference
//  between "the picture arrives 92 ms sooner" and "the video never plays" — there is
//  no degraded middle state to land in.
//
//  It lives here, out of the view, because it had a bug that the view could not be
//  asked about. `DetailStepTests` sets the strategy for this area out loud — the
//  logic lives beside the view and "should not be tested through the view" — so the
//  gate is a function over a sequence of statuses, and `VideoPosterGateTests` drives
//  it with sequences the view could never produce on demand: one that ends without
//  ever leaving `.unknown`, and one cancelled mid-wait.
//

import AVFoundation
import OSLog

/// When the poster comes down, and why.
///
/// **Every case is a lift.** That is the invariant this type exists to state: the
/// caller drops the poster on ANY return, and the reason is diagnostic only. The bug
/// (`.change-log/489`) was a wait that could end three ways while only one of them
/// lifted, so the reason is spelled out as a value rather than left implicit in
/// which line happened to run.
enum VideoPosterLift: Equatable {
    /// The player had no `currentItem` — there is nothing to wait on, and a poster
    /// held up for a player that will never load a thing is the stuck state itself.
    case noItem
    /// A real status arrived: the item either has a frame to draw or has failed
    /// trying. `.failed` lifts too, deliberately — see ``VideoPosterGate/firstFrame(statuses:lift:)``.
    case status(AVPlayerItem.Status)
    /// The status sequence ENDED without ever leaving `.unknown`: the surrounding
    /// `.task` was cancelled, or the observed item was deallocated.
    ///
    /// This is the case that used to strand the poster. It is not an error — a
    /// cancelled load is the ordinary result of stepping to the next item — but it
    /// is the one exit where nothing about the player itself has been learned.
    case sequenceEnded
}

/// The poster gate: wait for the first status worth acting on, and report why the
/// wait ended.
///
/// `@MainActor` because that is where `ItemDetailView.loadMedia` does all of this
/// (`VideoOpenProbeTests` measures it there for the same reason), and because it
/// keeps the status sequence on the caller's actor — no hop, so no `Sendable`
/// requirement on a Combine `AsyncPublisher` that does not advertise one.
@MainActor
enum VideoPosterGate {
    /// Wait until `statuses` yields anything other than `.unknown`.
    ///
    /// **`.failed` lifts the poster too, deliberately.** The alternative is a poster
    /// left up forever over a player that will never draw, which looks exactly like a
    /// working video that refuses to play — the player's own error state is the more
    /// honest thing to show, and a poster that stays would also hide the one signal a
    /// person could report.
    ///
    /// **Returning is the contract, not returning `.status`.** `for await` over an
    /// `AsyncPublisher` does not throw on cancellation — it simply ENDS, and the
    /// function returns normally. The version this replaces set the view's
    /// `videoReady` flag INSIDE the loop, so that ending was silent: the flag stayed
    /// false with the player already assigned, `.task(id: asset.id)` did not re-run
    /// for an id that had not changed, and an opaque still sat over a video that was
    /// playing underneath it for the life of the page. Reported as "it shows the
    /// initial frame, and when playing, the same frame is shown" — which is exactly
    /// what the poster is, a frame about a second into the clip
    /// (`ThumbnailTier.makeVideoPoster`).
    ///
    /// So the lift cannot live on one path out of three — and it does not live at the
    /// CALL SITE either. `lift` is invoked from a `defer` here, exactly once, on every
    /// path out of this function including cancellation. That is deliberate: a caller
    /// that has to remember to drop the poster is the same bug one refactor away, and
    /// a rule kept in a SwiftUI view is a rule no test can ask about. Keeping it in
    /// here is what makes `VideoPosterGateTests` able to assert it.
    @discardableResult
    static func firstFrame<S: AsyncSequence>(
        statuses: S?, lift: () -> Void
    ) async -> VideoPosterLift
    where S.Element == AVPlayerItem.Status, S.Failure == Never {
        // Logged on ENTRY, not only on the way out, and the difference cost a whole
        // debugging round trip: a gate that is entered and then never returns produces
        // exactly the same silence as one that is never called, and those two need
        // opposite fixes. An instrument that cannot separate them is not an instrument.
        AppLog.detail.notice("video poster gate: entered")
        defer { lift() }
        guard let statuses else {
            AppLog.detail.notice("video poster lifted: no player item")
            return .noItem
        }
        // EVERY status, `.unknown` included. The filtered-out ones are the evidence
        // that the sequence is alive at all — without them, "the publisher never
        // delivered anything" and "the item is stuck at .unknown" look identical from
        // outside, and again those want different fixes.
        for await status in statuses {
            AppLog.detail.notice("video poster gate: status \(status.rawValue, privacy: .public)")
            guard status != .unknown else { continue }
            AppLog.detail.notice("video poster lifted: status \(status.rawValue, privacy: .public)")
            return .status(status)
        }
        // Cancelled, or the item went away. The poster comes down either way; the
        // next item's `loadMedia` re-arms it, and there is no next item to re-arm it
        // for when the page is closing.
        AppLog.detail.notice("video poster lifted: status sequence ended without a status")
        return .sequenceEnded
    }
}
