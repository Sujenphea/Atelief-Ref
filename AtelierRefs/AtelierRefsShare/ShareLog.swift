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

import Foundation
import OSLog

nonisolated enum ShareLog {
    /// This process's own bundle identifier, with the build's spelling as the fallback.
    static let subsystem = Bundle.main.bundleIdentifier ?? "sujenphea.AtelierRefsMobile.Share"

    /// Everything the share does: what arrived, what the page held, what was written.
    static let share = Logger(subsystem: subsystem, category: "share")
}
