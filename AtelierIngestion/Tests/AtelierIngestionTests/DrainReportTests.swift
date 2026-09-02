// AtelierIngestion — the sentences a drain pass produces (098 · finding 5).
//
// `DrainSummary.reportLines` is the wording that used to be hand-copied between the Mac's
// `InboxDrainScheduler.report(_:)` and the phone's. It has no dependencies, no I/O and no
// clock, so every case it can produce is enumerable — which is the argument for moving it:
// the copies were tested by nothing on either platform, and what a phone's log says about a
// capture it gave up on is the first thing anyone asks when a share does not arrive.
//
// The tests assert three separate things and are grouped that way: WHICH lines a summary
// produces, at WHAT level, and in WHAT order. The wording itself is asserted literally,
// because the wording is the thing that moved and a paraphrase is a silent change to the
// only record two apps keep of a pass.
//
// The last group is `userNotice` (098 · P6), which is the other direction: not what the log
// records but what the phone puts on a screen, and its interesting cases are the four fates
// that produce NOTHING.

import Foundation
import Testing

@testable import AtelierIngestion

@Suite("DrainSummary: what a pass logs, and what it says out loud (098 · 5, P6)")
struct DrainReportTests {

    // MARK: - Silence

    @Test("a pass that did nothing says nothing")
    func emptySummaryIsSilent() {
        // The case both apps are in on nearly every launch and every foreground. A line
        // here would be a line per activation for the life of the app.
        #expect(DrainSummary().reportLines.isEmpty)
    }

    @Test("every count at zero with a readable inbox is silent, however it is spelled")
    func explicitZerosAreSilent() {
        let summary = DrainSummary(
            ingested: 0, skippedIncomplete: 0, quarantined: 0, retrying: 0,
            skippedExhausted: 0, inboxUnreadable: false)
        #expect(summary.reportLines.isEmpty)
    }

    // MARK: - The inbox itself

    @Test("an unreadable inbox is reported, at error")
    func unreadableInbox() {
        let lines = DrainSummary(inboxUnreadable: true).reportLines
        #expect(lines == [
            DrainReportLine(
                level: .error,
                text: "inbox could not be enumerated; captures left in place"),
        ])
    }

    @Test("a quarantine is reported, at error, with its count")
    func quarantined() {
        let lines = DrainSummary(quarantined: 3).reportLines
        #expect(lines == [
            DrainReportLine(level: .error, text: "3 capture(s) moved to inbox/failed/"),
        ])
    }

    @Test("a single quarantine still says capture(s) — the plural is not conditional")
    func quarantineOfOne() {
        #expect(DrainSummary(quarantined: 1).reportLines.first?.text
            == "1 capture(s) moved to inbox/failed/")
    }

    // MARK: - The counts

    /// The three counts that share one line, as (ingested, retrying, incomplete).
    ///
    /// Every non-zero combination of the three, so "which counts make the line appear" is
    /// asserted rather than sampled — the rule is an `||` over three values and a typo in
    /// it would hide a whole shape of pass from both logs.
    @Test(
        "any of ingested / retrying / incomplete produces the counts line",
        arguments: [
            (1, 0, 0), (0, 1, 0), (0, 0, 1),
            (1, 1, 0), (1, 0, 1), (0, 1, 1),
            (2, 3, 4),
        ])
    func countsLineAppears(counts: (ingested: Int, retrying: Int, incomplete: Int)) {
        let summary = DrainSummary(
            ingested: counts.ingested,
            skippedIncomplete: counts.incomplete,
            retrying: counts.retrying)
        #expect(summary.reportLines == [
            DrainReportLine(
                level: .notice,
                text: "inbox drain: \(counts.ingested) ingested, "
                    + "\(counts.retrying) retrying, \(counts.incomplete) incomplete"),
        ])
    }

    @Test("the counts line spells all three counts even when two are zero")
    func countsLineSpellsZeros() {
        // The line is the shape of a pass, not a list of what was non-zero: "5 ingested,
        // 0 retrying, 0 incomplete" is the sentence that says nothing went wrong.
        #expect(DrainSummary(ingested: 5).reportLines.first?.text
            == "inbox drain: 5 ingested, 0 retrying, 0 incomplete")
    }

    @Test("a quarantine alone does NOT produce a counts line")
    func quarantineIsNotACount() {
        // `quarantined` has its own line and is deliberately outside the `||` that gates
        // the counts, so a pass that only quarantined says one thing rather than two.
        let lines = DrainSummary(quarantined: 1).reportLines
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { !$0.text.hasPrefix("inbox drain:") })
    }

    // MARK: - The fate that had no voice

    @Test("an exhausted-but-retained capture is reported")
    func exhaustedIsReported() {
        // 098 · finding 5: phase 2 added `skippedExhausted` and NEITHER app's `report(_:)`
        // mentioned it, so a phone that had permanently stopped trying a capture said so
        // nowhere at all. This is the assertion that it has a voice.
        let lines = DrainSummary(skippedExhausted: 2).reportLines
        #expect(lines == [
            DrainReportLine(
                level: .notice,
                text: "2 capture(s) out of attempts; kept for export"),
        ])
    }

    @Test("exhausted is at notice, not error — it recurs on every pass by design")
    func exhaustedIsNotAnError() {
        // The record stays in the pending set, so every future pass counts it again. See
        // the comment on `reportLines` for why that is the whole argument for the level.
        #expect(DrainSummary(skippedExhausted: 1).reportLines.first?.level == .notice)
        #expect(DrainSummary(quarantined: 1).reportLines.first?.level == .error)
    }

    @Test("exhausted is a line of its own, not a fourth count")
    func exhaustedIsNotFoldedIn() {
        // Folding it into the counts line would print ", 0 exhausted" on the Mac forever,
        // for a fate only `.retainForExport` can produce.
        let lines = DrainSummary(ingested: 1, skippedExhausted: 1).reportLines
        #expect(lines.count == 2)
        #expect(lines[0].text == "inbox drain: 1 ingested, 0 retrying, 0 incomplete")
        #expect(lines[1].text == "1 capture(s) out of attempts; kept for export")
    }

    // MARK: - Order, and everything at once

    @Test("the inbox lines come before the counts, in a fixed order")
    func lineOrder() {
        let summary = DrainSummary(
            ingested: 1, skippedIncomplete: 2, quarantined: 3, retrying: 4,
            skippedExhausted: 5, inboxUnreadable: true)
        #expect(summary.reportLines == [
            DrainReportLine(
                level: .error,
                text: "inbox could not be enumerated; captures left in place"),
            DrainReportLine(level: .error, text: "3 capture(s) moved to inbox/failed/"),
            DrainReportLine(
                level: .notice,
                text: "inbox drain: 1 ingested, 4 retrying, 2 incomplete"),
            DrainReportLine(
                level: .notice, text: "5 capture(s) out of attempts; kept for export"),
        ])
    }

    @Test("an unreadable inbox does not suppress counts a caller can read for itself")
    func unreadableStillReportsCounts() {
        let lines = DrainSummary(ingested: 1, inboxUnreadable: true).reportLines
        #expect(lines.count == 2)
        #expect(lines[0].level == .error)
        #expect(lines[1].text == "inbox drain: 1 ingested, 0 retrying, 0 incomplete")
    }

    @Test("the report is pure: reading it twice gives the same lines")
    func reportIsPure() {
        let summary = DrainSummary(ingested: 1, quarantined: 1, skippedExhausted: 1)
        #expect(summary.reportLines == summary.reportLines)
    }

    // MARK: - The level vocabulary

    @Test("notice sorts below error, so a caller can filter on the loud half")
    func levelOrdering() {
        #expect(DrainReportLevel.notice < DrainReportLevel.error)
        #expect(DrainReportLevel.allCases == [.notice, .error])
    }

    // MARK: - What a person is told (098 · P6)

    @Test("the ordinary pass says nothing to anybody")
    func ordinaryPassIsSilent() {
        #expect(DrainSummary().userNotice == nil)
        #expect(DrainSummary(ingested: 12).userNotice == nil)
        #expect(DrainSummary(skippedIncomplete: 2, retrying: 1).userNotice == nil)
    }

    @Test("an exhausted-but-retained capture is deliberately silent")
    func exhaustedIsSilent() {
        // The one fate that is loud in the log and silent on screen. The drain has given
        // up; the record is still pending, the export still sends it, and the "Saved" the
        // share sheet showed is still true. See ``DrainSummary/userNotice``.
        #expect(DrainSummary(skippedExhausted: 4).userNotice == nil)
        #expect(DrainSummary(skippedExhausted: 4).reportLines.count == 1)
    }

    @Test("an unreadable inbox is said out loud, because every other surface says nothing")
    func unreadableInboxIsSaid() {
        #expect(
            DrainSummary(inboxUnreadable: true).userNotice
                == "This phone's inbox can't be read, so new shares aren't arriving.")
    }

    @Test("a quarantined capture is named, and its number agrees with the log")
    func quarantineIsSaid() {
        #expect(
            DrainSummary(quarantined: 1).userNotice
                == "1 capture couldn't be imported and won't reach your Mac.")
        #expect(
            DrainSummary(quarantined: 3).userNotice
                == "3 captures couldn't be imported and won't reach your Mac.")
    }

    @Test("an unreadable inbox wins over a quarantine — the counts beside it never ran")
    func unreadableWinsOverQuarantine() {
        let summary = DrainSummary(quarantined: 2, inboxUnreadable: true)
        #expect(summary.userNotice == "This phone's inbox can't be read, so new shares aren't arriving.")
        // The log still carries both, which is the difference between a notice and a report.
        #expect(summary.reportLines.count == 2)
    }

    @Test("the notice is pure: reading it twice gives the same sentence")
    func noticeIsPure() {
        let summary = DrainSummary(quarantined: 2)
        #expect(summary.userNotice == summary.userNotice)
    }

    @Test("every notice is one sentence and never names a count the user cannot check")
    func noticeShape() {
        // A notice is read on a phone, over a grid, once. Two conditions can produce one,
        // and both are asserted here as a SHAPE rather than only as a literal: one
        // sentence, ending in a full stop, short enough for the card that draws it.
        for summary in [
            DrainSummary(inboxUnreadable: true), DrainSummary(quarantined: 7),
        ] {
            let notice = try! #require(summary.userNotice)
            #expect(notice.hasSuffix("."))
            #expect(!notice.contains("\n"))
            #expect(notice.count <= 90)
        }
    }
}
