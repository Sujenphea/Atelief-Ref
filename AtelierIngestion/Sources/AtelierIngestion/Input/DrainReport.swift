// AtelierIngestion — what a pass says about itself, once, for both apps
// (098 · finding 5).
//
// `InboxDrainScheduler.report(_:)` existed twice, in `AtelierRefs` and in
// `AtelierRefsMobile`, byte-identical apart from `AppLog` vs `MobileLog`. 455 named the
// duplication and left it; 098 · finding 5 costed it. What was actually duplicated was
// never the logging — it was the WORDING and the RULES about when each sentence is worth
// saying, which is a property of the summary and of nothing else.
//
// So it lives here, on ``DrainSummary``, as a pure function. The apps keep the half that
// genuinely is theirs: which `Logger` the line goes to. Neither app decides any more what
// a pass is worth saying, or in which order, or at what level.
//
// **Levels, and why there are two.** `os.Logger` has six and this vocabulary has two,
// because the report only ever answered two questions: is this the ordinary shape of a
// pass, or is it the shape someone will want to have seen? A third level would be a
// distinction no caller has ever drawn. The mapping to `os` is the app's, one `switch`
// wide, which is also where a future app that is not `os.Logger`-shaped would differ.
//
// **Nothing here reaches the user**, which is the Mac's conclusion and 093 § 7's: an
// unreadable inbox and a quarantined capture are both conditions a person has no lever
// for, and the captures are still on disk either way.

import Foundation

/// How loud one line of a drain report is.
///
/// Two cases rather than a mirror of `os.LogLevel`: see the file header. `Comparable` so a
/// caller that only wants the loud half can filter without knowing the case names —
/// ``notice`` sorts below ``error``.
public enum DrainReportLevel: Sendable, Equatable, Comparable, CaseIterable {
    /// The ordinary shape of a pass: what it did, in counts.
    case notice
    /// Something a person will want to have seen, even though there is nothing they can
    /// do about it in the moment.
    case error
}

/// One line of a drain report: how loud it is, and what it says.
public struct DrainReportLine: Sendable, Equatable {
    public let level: DrainReportLevel
    public let text: String

    public init(level: DrainReportLevel, text: String) {
        self.level = level
        self.text = text
    }
}

extension DrainSummary {

    /// What this pass is worth saying, in order, or nothing at all.
    ///
    /// Empty for the pass both apps are in nearly always — an inbox with nothing in it —
    /// so "log every line of `reportLines`" costs a caller no guard of its own. A pass that
    /// did nothing says nothing; there is no line for it, because a line per foreground
    /// for a phone with an empty inbox is how a log stops being read.
    ///
    /// The order is fixed and asserted: the two conditions that describe the INBOX come
    /// first (it could not be read; some of it was moved out of the way for good), then the
    /// counts of what the pass did.
    public var reportLines: [DrainReportLine] {
        var lines: [DrainReportLine] = []

        if inboxUnreadable {
            // The four counts say nothing in this case, and they are still emitted below
            // if they are non-zero — a partially enumerated directory is not a state the
            // drain produces today, but a report that hid them would be lying about a
            // summary the caller can read for itself.
            lines.append(DrainReportLine(
                level: .error,
                text: "inbox could not be enumerated; captures left in place"))
        }

        if quarantined > 0 {
            lines.append(DrainReportLine(
                level: .error,
                text: "\(quarantined) capture(s) moved to inbox/failed/"))
        }

        if ingested > 0 || retrying > 0 || skippedIncomplete > 0 {
            lines.append(DrainReportLine(
                level: .notice,
                text: """
                    inbox drain: \(ingested) ingested, \
                    \(retrying) retrying, \
                    \(skippedIncomplete) incomplete
                    """))
        }

        if skippedExhausted > 0 {
            // **The fate neither app reported until now** (098 · finding 5).
            // `skippedExhausted` landed in phase 2 and no `report(_:)` mentioned it, so a
            // phone that had permanently given up on a capture said so nowhere.
            //
            // A line of its own rather than a fourth count on the notice above, because
            // only `InboxDrain.Retention.retainForExport` can produce it: folding it in
            // would print ", 0 exhausted" on the Mac forever for a fate the Mac does not
            // have.
            //
            // `.notice` and not `.error`, which is the one place this differs from a
            // quarantine. A quarantine happens ONCE and takes the record out of the
            // enumerated set. An exhausted-but-retained record stays pending, so every
            // pass for the rest of the library's life counts it again — an `.error` on
            // every foreground for a condition that recurs by design is how a log stops
            // being read. And nothing is lost: the record is still in the pending set and
            // the export still sends it, which is the whole reason this fate exists.
            lines.append(DrainReportLine(
                level: .notice,
                text: "\(skippedExhausted) capture(s) out of attempts; kept for export"))
        }

        return lines
    }
}
