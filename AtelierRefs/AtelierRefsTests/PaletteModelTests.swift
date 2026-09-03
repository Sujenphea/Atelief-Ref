//
//  PaletteModelTests.swift
//  AtelierRefsTests
//
//  099 · P6 — the floating reference palette's model: what it may show, what it
//  remembers, and the two ways it is asked for.
//
//  **The picker is not re-tested here.** It is P5's `SwitcherModel` over P5's
//  `SwitcherRanking`, and both are exhaustively covered by `SwitcherModelTests` and
//  `SwitcherRankingTests`. What IS tested is the one thing the palette adds on top —
//  the scope filter — and it is tested by comparison with ⌘K's list rather than in
//  isolation, because "these two surfaces search the same thing and differ in
//  exactly this way" is the claim P6 makes and the one a later change could break.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("The reference palette's model (099 · P6)", .timeLimit(.minutes(1)))
struct PaletteModelTests {

    /// A defaults suite per test, so nothing here reads or writes the developer's
    /// real preferences — `SwitcherRecentsTests`' pattern, and `GridDensity`'s.
    private func makeDefaults(_ label: String) throws -> UserDefaults {
        let name = "palette-\(label)-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    /// `sortIndex` is explicit wherever order is asserted: siblings tie-break by
    /// NAME (`BrowseCollectionTree.byManualOrder`), so two roots left at 0 would sort
    /// alphabetically and the test would be asserting the alphabet.
    private func collection(
        _ name: String, parent: UUID? = nil, id: UUID = UUID(), sortIndex: Int = 0
    ) -> Collection {
        Collection(
            id: id, name: name, createdAt: Date(), updatedAt: Date(),
            parentCollectionID: parent, sortIndex: sortIndex)
    }

    private func savedSearch(_ name: String, id: UUID = UUID()) -> SavedSearch {
        SavedSearch(
            id: id, name: name, rules: "{}", createdAt: Date(), updatedAt: Date())
    }

    private func space(_ name: String, id: UUID = UUID()) -> Space {
        Space(id: id, name: name, createdAt: Date(), updatedAt: Date())
    }

    // MARK: - What a palette may show

    /// The scope rule, over every case of the enum.
    ///
    /// Hand-listed rather than derived, because `SidebarItem` carries payloads and
    /// cannot be `CaseIterable` — the same trade `SmartCollectionExclusionTests`
    /// makes for `acceptsAssetDrops`. The production `switch` has no `default`, so a
    /// new case fails to compile until it answers; this list is what makes a new
    /// case fail a TEST too if someone answers it here and not there.
    @Test("only a collection and a saved search can be shown in the palette")
    func canShowIsCollectionsAndSavedSearchesOnly() {
        #expect(PaletteDestinations.canShow(.collection(UUID())))
        #expect(PaletteDestinations.canShow(.savedSearch(UUID())))
        #expect(!PaletteDestinations.canShow(.home))
        #expect(!PaletteDestinations.canShow(.capture))
        #expect(!PaletteDestinations.canShow(.shelf))
        #expect(!PaletteDestinations.canShow(.space(UUID())))
        #if DEBUG
        #expect(!PaletteDestinations.canShow(.theme))
        #endif
    }

    /// **A space in the palette is not in v1**, and this is where that is a fact
    /// rather than a sentence in a changelog. The candidate list is built WITH the
    /// spaces and then filtered, so the exclusion is a rule the test can see; handing
    /// the builder an empty array would make a bug look identical to the decision.
    @Test("a space is a ⌘K candidate and never a palette one")
    func aSpaceIsASwitcherCandidateAndNotAPaletteOne() {
        let unsorted = Collection.unsortedID
        let folders = [collection("Unsorted", id: unsorted), collection("Textures")]
        let spaces = [space("Moodboard")]

        let switcher = SwitcherRanking.candidates(
            folders: folders, unsortedID: unsorted, spaces: spaces, savedSearches: [])
        let palette = PaletteDestinations.candidates(
            folders: folders, unsortedID: unsorted, spaces: spaces, savedSearches: [])

        #expect(switcher.contains { $0.title == "Moodboard" })
        #expect(!palette.contains { $0.title == "Moodboard" })
    }

    /// Home, Capture and Archived are ⌘K's first three rows and none of them is a
    /// feed, so the palette's list starts at the collections and saved searches.
    @Test("the three fixed destinations are not palette candidates")
    func fixedDestinationsAreNotPaletteCandidates() {
        let unsorted = Collection.unsortedID
        let palette = PaletteDestinations.candidates(
            folders: [collection("Unsorted", id: unsorted)],
            unsortedID: unsorted, spaces: [], savedSearches: [])
        #expect(!palette.contains { $0.destination == .home })
        #expect(!palette.contains { $0.destination == .capture })
        #expect(!palette.contains { $0.destination == .shelf })
        #expect(palette.map(\.title) == ["Unsorted"])
    }

    /// The filter narrows the list and never re-orders it: the palette's rows are a
    /// SUBSEQUENCE of ⌘K's, so the two pickers agree about which of two `Inspiration`s
    /// comes first. That is the "shared ordering" half of "one search, two surfaces".
    @Test("the palette's candidates are ⌘K's, in ⌘K's order, minus what it cannot show")
    func paletteCandidatesAreASubsequenceOfTheSharedOrdering() {
        let unsorted = Collection.unsortedID
        let parent = UUID()
        let folders = [
            collection("Unsorted", id: unsorted),
            collection("Textures", id: parent, sortIndex: 0),
            collection("Concrete", parent: parent),
            collection("Posters", sortIndex: 1),
        ]
        let searches = [savedSearch("Warm Tones")]
        let spaces = [space("Moodboard")]

        let switcher = SwitcherRanking.candidates(
            folders: folders, unsortedID: unsorted, spaces: spaces, savedSearches: searches)
        let palette = PaletteDestinations.candidates(
            folders: folders, unsortedID: unsorted, spaces: spaces, savedSearches: searches)

        #expect(palette.map(\.title)
            == ["Warm Tones", "Unsorted", "Textures", "Concrete", "Posters"])
        // A subsequence check, not a set check: order is the thing being asserted.
        var remaining = switcher.map(\.destination)[...]
        for row in palette {
            guard let hit = remaining.firstIndex(of: row.destination) else {
                Issue.record("\(row.title) is not a ⌘K candidate at all")
                return
            }
            remaining = remaining[remaining.index(after: hit)...]
        }
    }

    /// The picker IS P5's — the same object, ranked by the same function. Asserted by
    /// driving both and comparing, so a future "small tweak" to one surface's ordering
    /// fails here rather than shipping two switchers that disagree.
    @Test("the picker ranks with P5's ranking, not a second one")
    func thePickerIsTheSharedRanking() throws {
        let unsorted = Collection.unsortedID
        let folders = [
            collection("Unsorted", id: unsorted),
            collection("Concrete Posters"),
            collection("Concrete"),
            collection("Reinforced Concrete"),
        ]
        let candidates = PaletteDestinations.candidates(
            folders: folders, unsortedID: unsorted, spaces: [], savedSearches: [])

        let palette = PaletteModel(defaults: try makeDefaults("ranking"))
        palette.picker.open(candidates: candidates, recents: [])
        palette.picker.query = "concrete"

        let expected = SwitcherRanking.results(for: "concrete", in: candidates, recents: [])
        #expect(palette.picker.results.map(\.destination) == expected.map(\.destination))
        // …and the ranking is doing real work: prefix beats word-start.
        #expect(palette.picker.results.first?.candidate.title == "Concrete")
    }

    /// The palette's picker deliberately does NOT read ⌘K's MRU. "Where I navigated
    /// recently" and "what I keep beside my work" are different questions, and the
    /// palette's memory answers the second one with a single destination.
    @Test("the picker's resting order is the shared ordering, with no MRU boost")
    func thePickerDoesNotUseTheSwitcherMru() throws {
        let unsorted = Collection.unsortedID
        let last = UUID()
        let folders = [
            collection("Unsorted", id: unsorted),
            collection("Alpha", sortIndex: 0),
            collection("Zulu", id: last, sortIndex: 1),
        ]
        let candidates = PaletteDestinations.candidates(
            folders: folders, unsortedID: unsorted, spaces: [], savedSearches: [])
        let palette = PaletteModel(defaults: try makeDefaults("no-mru"))
        // The palette's own picker, opened the way `PaletteDestinationPicker` opens
        // it: no recents at all.
        palette.picker.open(candidates: candidates, recents: [])
        #expect(palette.picker.results.map(\.candidate.title) == ["Unsorted", "Alpha", "Zulu"])
        // For contrast: the same candidates WITH `Zulu` as a recent put it first —
        // which is what ⌘K does and what the palette declines to do.
        let boosted = SwitcherRanking.results(
            for: "", in: candidates, recents: [.collection(last)])
        #expect(boosted.first?.candidate.title == "Zulu")
    }

    /// Both cases collapse to one `UUID` for the read model, and nothing else does.
    @Test("feedID answers for the two showable destinations and nothing else")
    func feedIDOfEachDestination() {
        let collectionID = UUID()
        let searchID = UUID()
        #expect(PaletteDestinations.feedID(of: .collection(collectionID)) == collectionID)
        #expect(PaletteDestinations.feedID(of: .savedSearch(searchID)) == searchID)
        #expect(PaletteDestinations.feedID(of: .home) == nil)
        #expect(PaletteDestinations.feedID(of: .space(UUID())) == nil)
    }

    // MARK: - The per-library memory

    @Test("the key is namespaced by library id, per 016 §C")
    func keyIsNamespacedByLibrary() {
        #expect(
            PaletteModel.defaultsKey(libraryID: "ABC123")
                == "library.ABC123.paletteDestination")
    }

    /// The fourth preference to take 016 §C's prefix (the clipboard toggle, the
    /// backup cadence, ⌘K's MRU, this). Compared against ANOTHER key rather than
    /// against a format string, `SwitcherRecentsTests`' rule: the day someone changes
    /// the namespace they have to change it in both places or fail here.
    @Test("the key shape is the switcher MRU's, not a second invention")
    func keyMatchesTheSwitcherRecentsShape() {
        let id = "ABC123"
        let mine = PaletteModel.defaultsKey(libraryID: id)
        let precedent = SwitcherRecents.defaultsKey(libraryID: id)
        let prefix = "library.\(id)."
        #expect(mine.hasPrefix(prefix))
        #expect(precedent.hasPrefix(prefix))
        #expect(mine != precedent)
    }

    @Test("what the palette last showed comes back on the next launch")
    func theLastShownDestinationIsRemembered() throws {
        let defaults = try makeDefaults("remember")
        let id = UUID()

        let first = PaletteModel(defaults: defaults)
        first.activate(libraryID: "LIB")
        first.show(.collection(id))

        let second = PaletteModel(defaults: defaults)
        #expect(second.destination == nil)
        second.activate(libraryID: "LIB")
        #expect(second.destination == .collection(id))
    }

    @Test("a saved search is remembered the same way a collection is")
    func aSavedSearchIsRemembered() throws {
        let defaults = try makeDefaults("remember-search")
        let id = UUID()
        let first = PaletteModel(defaults: defaults)
        first.activate(libraryID: "LIB")
        first.choose(.savedSearch(id))

        let second = PaletteModel(defaults: defaults)
        second.activate(libraryID: "LIB")
        #expect(second.destination == .savedSearch(id))
    }

    @Test("two libraries remember different destinations")
    func twoLibrariesDoNotShareADestination() throws {
        let defaults = try makeDefaults("two-libraries")
        let a = UUID()
        let b = UUID()

        let first = PaletteModel(defaults: defaults)
        first.activate(libraryID: "A")
        first.show(.collection(a))
        let second = PaletteModel(defaults: defaults)
        second.activate(libraryID: "B")
        second.show(.collection(b))

        let reopenedA = PaletteModel(defaults: defaults)
        reopenedA.activate(libraryID: "A")
        #expect(reopenedA.destination == .collection(a))
    }

    /// ``SwitcherRecents/record(_:)``'s rule, and 016 §C's: nothing is written to an
    /// un-namespaced key "for now", because that is exactly the migration the prefix
    /// exists to avoid. The palette still SHOWS the destination for this session.
    @Test("showing before the library opens writes nothing")
    func showBeforeActivateWritesNothing() throws {
        let defaults = try makeDefaults("before-activate")
        let id = UUID()
        let model = PaletteModel(defaults: defaults)
        model.show(.collection(id))

        #expect(model.destination == .collection(id))
        #expect(defaults.string(forKey: PaletteModel.defaultsKey(libraryID: "LIB")) == nil)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy {
            !$0.contains("paletteDestination")
        })
    }

    /// The stored value is a ``SwitcherRecents`` token, so a stored destination the
    /// palette cannot show — hand-written, or persisted by a version that could show
    /// spaces — is dropped rather than restored into a window that cannot render it.
    @Test("a stored destination the palette cannot show is ignored")
    func anUnshowableStoredTokenIsIgnored() throws {
        let defaults = try makeDefaults("unshowable")
        let token = try #require(SwitcherRecents.token(for: .space(UUID())))
        defaults.set(token, forKey: PaletteModel.defaultsKey(libraryID: "LIB"))

        let model = PaletteModel(defaults: defaults)
        model.activate(libraryID: "LIB")
        #expect(model.destination == nil)
    }

    @Test("a stored value that is not a token at all is ignored")
    func anUnparsableStoredTokenIsIgnored() throws {
        let defaults = try makeDefaults("unparsable")
        defaults.set("collection:not-a-uuid", forKey: PaletteModel.defaultsKey(libraryID: "LIB"))

        let model = PaletteModel(defaults: defaults)
        model.activate(libraryID: "LIB")
        #expect(model.destination == nil)
    }

    /// The token vocabulary is ⌘K's, not a second encoding of the same thing — so a
    /// rename of one spelling cannot silently orphan the other.
    @Test("the stored value is the switcher's token spelling")
    func theStoredValueIsASwitcherToken() throws {
        let defaults = try makeDefaults("token-spelling")
        let id = UUID()
        let model = PaletteModel(defaults: defaults)
        model.activate(libraryID: "LIB")
        model.show(.collection(id))

        let stored = defaults.string(forKey: PaletteModel.defaultsKey(libraryID: "LIB"))
        #expect(stored == SwitcherRecents.token(for: .collection(id)))
    }

    // MARK: - Raising the window

    /// A COUNTER, not a flag. Two "Open in Palette" clicks on the same row must both
    /// raise the window, and a boolean would need whoever consumed it to reset it —
    /// which is how the second click comes to do nothing.
    @Test("show raises the window every time, including for the same destination")
    func showRaisesTheWindowEveryTime() throws {
        let model = PaletteModel(defaults: try makeDefaults("pulse"))
        let id = UUID()
        #expect(model.openPulse == 0)
        model.show(.collection(id))
        #expect(model.openPulse == 1)
        model.show(.collection(id))
        #expect(model.openPulse == 2)
    }

    /// The picker inside the palette commits through `choose`, which must NOT order
    /// the window forward: it is already up, and an always-on-top window that raises
    /// itself over the app the user is designing in is the one thing it must not do
    /// unasked.
    @Test("choosing from inside the palette does not re-raise the window")
    func chooseDoesNotRaiseTheWindow() throws {
        let model = PaletteModel(defaults: try makeDefaults("choose"))
        model.isPickingDestination = true
        model.choose(.collection(UUID()))
        #expect(model.openPulse == 0)
        #expect(!model.isPickingDestination)
    }

    @Test("a destination the palette cannot show is refused by both entry points")
    func unshowableDestinationsAreRefused() throws {
        let model = PaletteModel(defaults: try makeDefaults("refuse"))
        model.show(.space(UUID()))
        #expect(model.destination == nil)
        #expect(model.openPulse == 0)
        model.choose(.home)
        #expect(model.destination == nil)
    }

    // MARK: - Reconciling with a library that changed

    @Test("a deleted collection stops being the palette's subject")
    func reconcileForgetsADeletedCollection() throws {
        let defaults = try makeDefaults("reconcile-collection")
        let unsorted = collection("Unsorted")
        let gone = collection("Gone")
        let model = PaletteModel(defaults: defaults)
        model.activate(libraryID: "LIB")
        model.show(.collection(gone.id))

        model.reconcile(folders: [unsorted], savedSearches: [])
        #expect(model.destination == nil)
        // …and it opens on its picker rather than on an empty grid.
        #expect(model.isPickingDestination)
        // …and it is not restored on the next launch either.
        #expect(defaults.string(forKey: PaletteModel.defaultsKey(libraryID: "LIB")) == nil)
    }

    @Test("a deleted saved search stops being the palette's subject")
    func reconcileForgetsADeletedSavedSearch() throws {
        let model = PaletteModel(defaults: try makeDefaults("reconcile-search"))
        model.activate(libraryID: "LIB")
        model.show(.savedSearch(UUID()))
        model.reconcile(folders: [collection("Unsorted")], savedSearches: [])
        #expect(model.destination == nil)
    }

    @Test("a destination that still exists survives reconciliation")
    func reconcileKeepsALiveDestination() throws {
        let model = PaletteModel(defaults: try makeDefaults("reconcile-live"))
        let live = collection("Textures")
        model.activate(libraryID: "LIB")
        model.show(.collection(live.id))
        model.reconcile(folders: [collection("Unsorted"), live], savedSearches: [])
        #expect(model.destination == .collection(live.id))
    }

    /// **The guard that makes "remembers what it last showed" true.** Every library
    /// has an Unsorted row, so an EMPTY folder list means the library has not
    /// published yet — and reconciling against it would drop the restored destination
    /// on every single launch, which looks exactly like the memory not working.
    @Test("reconciling before the library publishes keeps the restored destination")
    func reconcileBeforeTheLibraryPublishesKeepsTheDestination() throws {
        let model = PaletteModel(defaults: try makeDefaults("reconcile-early"))
        let id = UUID()
        model.activate(libraryID: "LIB")
        model.show(.collection(id))
        model.reconcile(folders: [], savedSearches: [])
        #expect(model.destination == .collection(id))
    }
}
