// AtelierRefsShare — the extension's one logger (092 · S4b-ii, 098 · P5).
//
// **Why a file for two lines.** `ShareViewController` used to own this as a `private
// static let`, which was fine while the extension was one file. 098 · finding 7 split
// that file into four, and a logger that lives on one of them would have meant either a
// second `Logger` (a second subsystem, silently, in the process whose whole diagnostic
// story is the unified log) or three files reaching into a fourth's private state.
//
// It is the phone's `MobileLog` at the size an extension needs it: one subsystem, one
// category, spelled once.
//
// `nonisolated` for the reason the controller's copy was: `NSItemProvider` calls its
// handlers on whatever thread it likes, and a log line from inside one of those handlers
// is exactly where a share that went wrong is diagnosed. `Logger` is `Sendable` and
// os_log is thread-safe, so the isolation was never buying anything — it was only making
// the diagnostic unreachable from the place that needs it.

import AtelierCapture
import Foundation
import OSLog

nonisolated enum ShareLog {
    /// This process's own bundle identifier, with the build's spelling as the fallback.
    ///
    /// **The fallback is a constant and not a literal** (098 · finding 7). It was
    /// `"sujenphea.AtelierRefsMobile.Share"`, hand-spelled here, beside a second
    /// hand-spelling of the phone app's own identifier as `MobileLog.subsystem` — two
    /// strings, in two targets, describing one `PRODUCT_BUNDLE_IDENTIFIER`, and an edit to
    /// that setting would have rotted both without breaking or warning anything.
    /// ``CompanionBundle`` is the one spelling, in the package both targets link, with a
    /// test that reads the identifiers back out of `project.pbxproj`. `MobileLog` adopts it
    /// in P6, which is the phase allowed to edit the phone app.
    ///
    /// `Bundle.main.bundleIdentifier` is still preferred over the constant: it is what this
    /// process actually IS, where the constant is only what it is supposed to be.
    static let subsystem = Bundle.main.bundleIdentifier ?? CompanionBundle.shareExtension

    /// Everything the share does: what arrived, what the page held, what was written.
    static let share = Logger(subsystem: subsystem, category: "share")
}
