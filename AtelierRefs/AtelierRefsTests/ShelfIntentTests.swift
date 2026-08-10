//
//  ShelfIntentTests.swift
//  AtelierRefsTests
//
//  023 · A3 — the archive verb's whole decision matrix, in the shape
//  `DeleteIntentTests` pins `deleteIntent`: a pure function, every combination
//  enumerated, no view and no `NSEvent`.
//
//  The rule under test, stated once so a future reader does not have to
//  reverse-engineer it from assertions:
//
//      The verb ARCHIVES unless every target is already archived, in which case
//      it UNARCHIVES.
//
//  Which is to say a MIXED selection converges to "all archived" rather than
//  flipping each item — the same convergence ⌘D already uses for the star
//  (011 · U5), and the only outcome a user can predict without inspecting every
//  tile.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("ShelfIntent — the archive verb (023 · A3)")
struct ShelfIntentTests {

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    // MARK: - The matrix

    @Test("an empty selection has no verb at all")
    func emptyHasNoVerb() {
        // `nil` rather than a zero-count verb: a menu omits the item instead of
        // offering a no-op, and a key press falls through instead of being
        // swallowed by a surface that had nothing to do.
        #expect(shelfVerb(targets: [], archived: []) == nil)
        #expect(shelfVerb(targets: [], archived: [a, b]) == nil)
    }

    @Test("nothing archived → archive, counted")
    func noneArchived() {
        #expect(shelfVerb(targets: [a], archived: []) == .archive(count: 1))
        #expect(shelfVerb(targets: [a, b, c], archived: []) == .archive(count: 3))
    }

    @Test("everything archived → unarchive, counted")
    func allArchived() {
        #expect(shelfVerb(targets: [a], archived: [a]) == .unarchive(count: 1))
        #expect(shelfVerb(targets: [a, b], archived: [a, b]) == .unarchive(count: 2))
    }

    /// The case the type exists for. A mixed selection must produce ONE
    /// predictable outcome, not a per-item flip that leaves the user with a
    /// different mixture than they started with.
    @Test("a mixed selection converges to archive, never flips")
    func mixedConverges() {
        #expect(shelfVerb(targets: [a, b], archived: [a]) == .archive(count: 2))
        #expect(shelfVerb(targets: [a, b, c], archived: [a, c]) == .archive(count: 3))
        // One un-archived item among many archived is still a mix, and still
        // archives — the rule does not soften with the ratio.
        #expect(shelfVerb(targets: [a, b, c], archived: [b, c]) == .archive(count: 3))
    }

    /// A second press is the inverse, which is what lets the verb read as a
    /// toggle: mixed → all archived → (press again) → all unarchived.
    @Test("pressing twice on a mixed selection is archive then unarchive")
    func secondPressIsTheInverse() {
        let targets = [a, b, c]
        let first = shelfVerb(targets: targets, archived: [a])
        #expect(first == .archive(count: 3))
        // After that archive, every target is archived…
        let second = shelfVerb(targets: targets, archived: [a, b, c])
        #expect(second == .unarchive(count: 3))
    }

    // MARK: - Input hygiene

    /// A caller may hold a wider set of known-archived ids than it is acting on
    /// (the shelf knows every archived item; a menu acts on three of them).
    @Test("archived ids outside the target set are ignored")
    func widerArchivedSetIsIgnored() {
        #expect(shelfVerb(targets: [a], archived: [a, b, c]) == .unarchive(count: 1))
        #expect(shelfVerb(targets: [a], archived: [b, c]) == .archive(count: 1))
    }

    /// Widening a selection to whole posts (307) can name the same asset twice.
    /// The count a menu shows has to be the number of ITEMS acted on, not the
    /// length of a list that happens to repeat.
    @Test("duplicate targets collapse rather than inflating the count")
    func duplicatesCollapse() {
        #expect(shelfVerb(targets: [a, a, a], archived: []) == .archive(count: 1))
        #expect(shelfVerb(targets: [a, b, a], archived: []) == .archive(count: 2))
        #expect(shelfVerb(targets: [a, a], archived: [a]) == .unarchive(count: 1))
    }

    // MARK: - Titles

    @Test("titles count the way every other grid verb counts")
    func titles() {
        #expect(ShelfVerb.archive(count: 1).title == "Archive")
        #expect(ShelfVerb.archive(count: 3).title == "Archive (3)")
        #expect(ShelfVerb.unarchive(count: 1).title == "Unarchive")
        #expect(ShelfVerb.unarchive(count: 12).title == "Unarchive (12)")
    }

    @Test("completed messages read as past tense, singular and plural")
    func completedMessages() {
        // Counted even at one — a mixed press changes fewer rows than it was
        // aimed at, and "Archived." would let the user read it as all of them.
        #expect(ShelfVerb.archive(count: 1).completedMessage == "Archived 1 item")
        #expect(ShelfVerb.archive(count: 4).completedMessage == "Archived 4 items")
        #expect(ShelfVerb.unarchive(count: 1).completedMessage == "Unarchived 1 item")
        #expect(ShelfVerb.unarchive(count: 2).completedMessage == "Unarchived 2 items")
    }

    @Test("count reports what the verb acts on")
    func countAccessor() {
        #expect(ShelfVerb.archive(count: 7).count == 7)
        #expect(ShelfVerb.unarchive(count: 2).count == 2)
    }

    // MARK: - The surfaces, expressed as the inputs they actually supply

    /// Each surface knows its own archived set without asking the database,
    /// because A1 guarantees it: browsing reads hide archived items, and the
    /// shelf shows only archived ones. These are those three call shapes.
    @Test("the three real call sites resolve to the right verb")
    func surfacesResolveCorrectly() {
        let selection = [a, b]
        // A collection grid, a search result page, a Space board: nothing they
        // can show is archived.
        #expect(shelfVerb(targets: selection, archived: []) == .archive(count: 2))
        // The shelf: everything it shows is.
        #expect(shelfVerb(targets: selection, archived: Set(selection))
            == .unarchive(count: 2))
        // The detail page, which knows one item's own state either way.
        #expect(shelfVerb(targets: [a], archived: []) == .archive(count: 1))
        #expect(shelfVerb(targets: [a], archived: [a]) == .unarchive(count: 1))
    }
}
