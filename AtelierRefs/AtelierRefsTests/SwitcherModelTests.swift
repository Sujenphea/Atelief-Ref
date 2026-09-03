//
//  SwitcherModelTests.swift
//  AtelierRefsTests
//
//  099 · P5 — the ⌘K panel's state machine: what a fresh open looks like, what a
//  keystroke does to the cursor, and what Return would take.
//
//  The RANKING is `SwitcherRankingTests`'. What is asserted here is the part of the
//  switcher that is a small stateful object rather than a function — and in
//  particular the two rules that make Return safe: the cursor is never on a row
//  that is not showing, and it is never nowhere while there is something to pick.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("The ⌘K panel's model: the query, the cursor and what Return commits",
       .timeLimit(.minutes(1)))
struct SwitcherModelTests {

    private func candidates(_ titles: [String]) -> [SwitcherCandidate] {
        titles.map {
            SwitcherCandidate(
                destination: .collection(UUID()), title: $0, detail: "", symbol: "folder")
        }
    }

    // MARK: - Opening

    @Test("opening seeds the cursor at the first row, so Return works untouched")
    func openSeedsTheCursor() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta"])
        model.open(candidates: rows, recents: [])
        #expect(model.query.isEmpty)
        #expect(model.results.count == 2)
        #expect(model.highlighted == rows[0].destination)
        #expect(model.commitTarget == rows[0].destination)
    }

    @Test("opening CLEARS the previous query")
    func openClearsThePreviousQuery() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta"])
        model.open(candidates: rows, recents: [])
        model.query = "beta"
        #expect(model.results.count == 1)

        // The second ⌘K of the session. A panel that came back on the last needle
        // would make the next keystroke append to it, which is the one way a
        // switcher can quietly send you somewhere you did not ask for.
        model.open(candidates: rows, recents: [])
        #expect(model.query.isEmpty)
        #expect(model.results.count == 2)
    }

    @Test("opening with an MRU leads with it")
    func openHonoursTheMru() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta"])
        model.open(candidates: rows, recents: [rows[1].destination])
        #expect(model.results.first?.destination == rows[1].destination)
        #expect(model.highlighted == rows[1].destination)
    }

    // MARK: - Typing

    @Test("typing re-ranks, and the cursor stays on a row that survived")
    func cursorSurvivesAKeystrokeWhenItsRowDoes() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta", "Betamax"])
        model.open(candidates: rows, recents: [])
        model.query = "beta"
        #expect(model.results.map(\.candidate.title) == ["Beta", "Betamax"])
        model.move(1)
        #expect(model.highlighted == rows[2].destination)

        // `Betamax` still matches `betam`, so the cursor does not jump back to the
        // top under the user's fingers.
        model.query = "betam"
        #expect(model.highlighted == rows[2].destination)
    }

    @Test("the cursor goes back to the top when its row stops matching")
    func cursorReseedsWhenItsRowIsFilteredOut() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta"])
        model.open(candidates: rows, recents: [])
        model.move(1)
        #expect(model.highlighted == rows[1].destination)

        model.query = "alpha"
        // Leaving it on `Beta` would leave Return pointed at a row that is not on
        // screen, which is the switcher's version of filing into nothing.
        #expect(model.highlighted == rows[0].destination)
    }

    @Test("no match means no cursor and nothing to commit")
    func noResultsMeansNothingToCommit() {
        let model = SwitcherModel()
        model.open(candidates: candidates(["Alpha"]), recents: [])
        model.query = "zzz"
        #expect(model.results.isEmpty)
        #expect(model.highlighted == nil)
        #expect(model.commitTarget == nil)
    }

    // MARK: - The cursor

    @Test("the arrows are clamped at both ends")
    func arrowsAreClamped() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta", "Gamma"])
        model.open(candidates: rows, recents: [])

        model.move(-1)
        // A ↑ on the first row is a stop, not a wrap — `CollectionDestinationList`'s
        // rule, which this now shares rather than restates.
        #expect(model.highlighted == rows[0].destination)
        model.move(1)
        model.move(1)
        model.move(1)
        #expect(model.highlighted == rows[2].destination)
    }

    @Test("a pointer may move the cursor, but only onto a row that is offered")
    func highlightIgnoresARowThatIsNotOffered() {
        let model = SwitcherModel()
        let rows = candidates(["Alpha", "Beta"])
        model.open(candidates: rows, recents: [])
        model.query = "alpha"

        model.highlight(rows[1].destination)
        #expect(model.highlighted == rows[0].destination)
        model.highlight(rows[0].destination)
        #expect(model.highlighted == rows[0].destination)
    }

    @Test("an empty candidate list is an empty panel, not a crash")
    func emptyLibrary() {
        let model = SwitcherModel()
        model.open(candidates: [], recents: [])
        #expect(model.results.isEmpty)
        #expect(model.highlighted == nil)
        model.move(1)
        #expect(model.highlighted == nil)
    }
}
