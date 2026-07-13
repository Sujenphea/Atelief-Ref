// AtelierCore — snapshot filename convention tests (008 H3)
//
// makeURL → parse round-trips reason + second-precision timestamp; parsing
// rejects non-snapshots; the longest reason prefix wins.

import Foundation
import Testing
@testable import AtelierCore

@Suite("SnapshotFile naming")
struct SnapshotFileTests {
    private let dir = URL(fileURLWithPath: "/tmp/snaps", isDirectory: true)

    @Test("makeURL → SnapshotFile round-trips reason and timestamp (to the second)")
    func roundTrip() throws {
        // A fixed, whole-second instant so the second-precision format is exact.
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        for reason in SnapshotReason.allCases {
            let url = SnapshotFile.makeURL(in: dir, reason: reason, date: date, id: "abc123")
            let parsed = try #require(SnapshotFile(url: url))
            #expect(parsed.reason == reason)
            #expect(parsed.date == date)
        }
    }

    @Test("parsing rejects non-.sqlite and unknown-prefix names")
    func rejectsNonSnapshots() {
        #expect(SnapshotFile(url: dir.appendingPathComponent("library.sqlite")) == nil)
        #expect(SnapshotFile(url: dir.appendingPathComponent("daily-nope.sqlite")) == nil)
        #expect(SnapshotFile(url: dir.appendingPathComponent("manual-20260101-000000-x.txt")) == nil)
    }

    @Test("the longest reason prefix wins (pre-migration, not a shorter match)")
    func longestPrefixWins() throws {
        let url = SnapshotFile.makeURL(
            in: dir, reason: .preMigration,
            date: Date(timeIntervalSince1970: 1_770_000_000), id: "z9")
        let parsed = try #require(SnapshotFile(url: url))
        #expect(parsed.reason == .preMigration)
    }
}
