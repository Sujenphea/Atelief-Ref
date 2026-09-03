//
//  SwitcherRankingTests.swift
//  AtelierRefsTests
//
//  099 · P5 — **the ⌘K ranking, tier by tier.**
//
//  The switcher's whole promise is that the row you meant is the row Return takes,
//  and that promise is a sort with three keys in it: the match tier, then the MRU,
//  then the shared ordering. A ranking asserted only end-to-end — "typing `con`
//  opens Concrete" — passes for the wrong reasons the moment the library has two
//  Concretes, so each tier gets its own test here, then each SORT KEY gets one, and
//  only then the two of them together.
//
//  Candidates are built from plain `Collection` / `Space` / `SavedSearch` values
//  rather than a temporary database: `SwitcherRanking` is pure and reads only the
//  fields below, so a database would add seconds to the suite and prove nothing
//  extra. The ORDERING those candidates come back in is the one thing that IS
//  worth checking against the real tree builder, and it is —
//  `CollectionTargets.destinationTree` is what `candidates(…)` calls.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("The ⌘K ranking: prefix > word-start > substring, recents, shared order",
       .timeLimit(.minutes(1)))
struct SwitcherRankingTests {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func collection(
        _ name: String, id: UUID = UUID(), parent: UUID? = nil, index: Int = 0
    ) -> Collection {
        Collection(
            id: id, name: name, createdAt: Self.epoch, updatedAt: Self.epoch,
            parentCollectionID: parent, sortIndex: index)
    }

    private func space(_ name: String, id: UUID = UUID(), index: Int = 0) -> Space {
        Space(id: id, name: name, createdAt: Self.epoch, updatedAt: Self.epoch, sortIndex: index)
    }

    private func savedSearch(_ name: String, id: UUID = UUID()) -> SavedSearch {
        SavedSearch(
            id: id, name: name, rules: "{}", createdAt: Self.epoch, updatedAt: Self.epoch)
    }

    /// A candidate list with named titles and no library behind it — for the sort
    /// tests, where what a row IS does not matter, only where it lands.
    private func candidates(_ titles: [String]) -> [SwitcherCandidate] {
        titles.map {
            SwitcherCandidate(
                destination: .collection(UUID()), title: $0, detail: "", symbol: "folder")
        }
    }

    // MARK: - Tier 1: prefix

    @Test("a title that STARTS with the query is a prefix match")
    func prefixTier() {
        #expect(SwitcherRanking.rank("Concrete", matching: "con") == .prefix)
        #expect(SwitcherRanking.rank("Concrete", matching: "Concrete") == .prefix)
        #expect(SwitcherRanking.rank("Concrete", matching: "c") == .prefix)
        // Leading/trailing whitespace in the QUERY is trimmed — a user who typed a
        // space before the word still meant the word.
        #expect(SwitcherRanking.rank("Concrete", matching: "  con ") == .prefix)
    }

    // MARK: - Tier 2: word start

    @Test("a query that starts a LATER word is a word-start match, not a prefix")
    func wordStartTier() {
        #expect(SwitcherRanking.rank("Warm Concrete", matching: "con") == .wordStart)
        // …and a query that spans the space is still measured from where it lands,
        // which here is the start of the string.
        #expect(SwitcherRanking.rank("Warm Concrete", matching: "warm con") == .prefix)
    }

    @Test("a word boundary is anything that is not a letter or a digit")
    func wordStartSeparators() {
        // Every separator a collection name in this app plausibly carries.
        for separator in ["-", "_", "/", ".", " ", "(", "&", "…"] {
            let title = "Type\(separator)Serif"
            #expect(
                SwitcherRanking.rank(title, matching: "serif") == .wordStart,
                "“\(title)” should start a word after “\(separator)”")
        }
        // A digit does NOT end a word — `Type2Serif` is one word, and the `S` in it
        // is mid-word.
        #expect(SwitcherRanking.rank("Type2Serif", matching: "serif") == .substring)
    }

    @Test("camel case is deliberately NOT a word boundary")
    func camelCaseIsNotABoundary() {
        // `TypeSerif` reads as two words to a human and one to this ranking, which
        // is the documented trade: splitting there would also split `iOS` at the
        // `O`. It still matches — as a substring.
        #expect(SwitcherRanking.rank("TypeSerif", matching: "serif") == .substring)
    }

    // MARK: - Tier 3: substring

    @Test("a query found only mid-word is a substring match")
    func substringTier() {
        #expect(SwitcherRanking.rank("Concrete", matching: "ncr") == .substring)
        #expect(SwitcherRanking.rank("Concrete", matching: "ete") == .substring)
    }

    @Test("a query that is nowhere in the title does not match at all")
    func noMatch() {
        #expect(SwitcherRanking.rank("Concrete", matching: "zzz") == nil)
        #expect(SwitcherRanking.rank("Concrete", matching: "cnrt") == nil)  // no subsequence tier
        #expect(SwitcherRanking.rank("", matching: "a") == nil)
    }

    // MARK: - The tiers together

    @Test("the BEST occurrence in a title decides its tier")
    func bestOccurrenceWins() {
        // The first `post` is mid-word (`Repost`); the second starts a word. A scan
        // that stopped at the first hit would rank this `.substring` and bury it
        // under every genuine word-start match.
        #expect(SwitcherRanking.rank("Repost Posters", matching: "post") == .wordStart)
        // …and a prefix still beats a later word start.
        #expect(SwitcherRanking.rank("Post Reposts", matching: "post") == .prefix)
    }

    @Test("matching folds case and diacritics on both sides")
    func caseAndDiacriticsFold() {
        #expect(SwitcherRanking.rank("Café", matching: "cafe") == .prefix)
        #expect(SwitcherRanking.rank("cafe", matching: "CAFÉ") == .prefix)
        #expect(SwitcherRanking.rank("Zürich Posters", matching: "zurich") == .prefix)
    }

    @Test("an empty query is a prefix of every title")
    func emptyQueryIsAPrefixOfEverything() {
        #expect(SwitcherRanking.rank("Concrete", matching: "") == .prefix)
        #expect(SwitcherRanking.rank("Concrete", matching: "   ") == .prefix)
    }

    // MARK: - Sort key 1: the tier

    @Test("results are ordered prefix, then word-start, then substring")
    func tierIsTheFirstSortKey() {
        // Deliberately listed WORST first, so a sort that did nothing would fail.
        let rows = candidates(["Bacon", "Warm Concrete", "Concrete"])
        let results = SwitcherRanking.results(for: "con", in: rows)
        #expect(results.map(\.candidate.title) == ["Concrete", "Warm Concrete", "Bacon"])
        #expect(results.map(\.rank) == [.prefix, .wordStart, .substring])
    }

    // MARK: - Sort key 2: recents

    @Test("within a tier, a recent destination comes first — most recent first")
    func recentsAreTheSecondSortKey() {
        let rows = candidates(["Concrete A", "Concrete B", "Concrete C"])
        // All three are prefix matches, so only the MRU can separate them.
        let recents = [rows[2].destination, rows[1].destination]
        let results = SwitcherRanking.results(for: "concrete", in: rows, recents: recents)
        #expect(results.map(\.candidate.title) == ["Concrete C", "Concrete B", "Concrete A"])
    }

    @Test("recency does NOT outrank the tier")
    func recencyNeverBeatsTheTier() {
        let rows = candidates(["Concrete", "Bacon"])
        // `Bacon` is the most recently visited place in the library and still sits
        // below a prefix match. A switcher that put it first would answer `con` with
        // the thing the query matches worst.
        let results = SwitcherRanking.results(
            for: "con", in: rows, recents: [rows[1].destination])
        #expect(results.map(\.candidate.title) == ["Concrete", "Bacon"])
    }

    @Test("a recent that no longer exists is simply not a result")
    func staleRecentsAreIgnored() {
        let rows = candidates(["Concrete"])
        let results = SwitcherRanking.results(
            for: "con", in: rows, recents: [.collection(UUID()), rows[0].destination])
        #expect(results.map(\.candidate.title) == ["Concrete"])
    }

    // MARK: - Sort key 3: the shared ordering

    @Test("ties fall back to the shared ordering, not to the alphabet")
    func sharedOrderingIsTheLastSortKey() {
        // Three equally-good prefix matches, none of them recent. The order they
        // come back in is the order they were HANDED IN — which is the sidebar's.
        // An alphabetical answer would be Ada, Bo, Zed and would pass a weaker test.
        let rows = candidates(["Zed", "Ada", "Bo"])
        let results = SwitcherRanking.results(for: "", in: rows)
        #expect(results.map(\.candidate.title) == ["Zed", "Ada", "Bo"])
    }

    @Test("an empty query lists the MRU first, then the shared ordering")
    func emptyQueryIsTheRestingList() {
        let rows = candidates(["Zed", "Ada", "Bo"])
        let results = SwitcherRanking.results(
            for: "", in: rows, recents: [rows[1].destination])
        // Ada was visited last, so it leads; the rest keep the sidebar's order.
        #expect(results.map(\.candidate.title) == ["Ada", "Zed", "Bo"])
    }

    @Test("the result cap keeps the BEST matches, not the first ones seen")
    func resultsAreCapped() {
        // 60 substring matches followed by one prefix match, capped at 3.
        var rows = candidates((0..<60).map { "Bacon \($0)" })
        rows += candidates(["Concrete"])
        let results = SwitcherRanking.results(for: "con", in: rows, limit: 3)
        #expect(results.count == 3)
        #expect(results.first?.candidate.title == "Concrete")
    }

    // MARK: - The candidates, and the shared ordering they arrive in

    @Test("the candidate list is the sidebar read top to bottom")
    func candidatesAreTheSharedOrdering() {
        let unsorted = Collection.unsortedID
        let textures = UUID()
        let folders = [
            collection("Unsorted", id: unsorted, index: 0),
            collection("Textures", id: textures, index: 0),
            collection("Concrete", parent: textures, index: 0),
            collection("Posters", index: 1),
        ]
        let all = SwitcherRanking.candidates(
            folders: folders, unsortedID: unsorted,
            spaces: [space("Moodboard")],
            savedSearches: [savedSearch("Warm Tones")])

        #expect(all.map(\.title) == [
            // The three fixed destinations, in the sidebar's nav-section order…
            "Home", "Capture", "Archived",
            // …then Spaces, then Smart, then the collection tree pre-order with
            // Unsorted pinned and the nested collection under its parent.
            "Moodboard", "Warm Tones",
            "Unsorted", "Textures", "Concrete", "Posters",
        ])
    }

    @Test("a nested collection carries its ancestor path; a root carries its section")
    func detailLinesSayWhereARowLives() {
        let unsorted = Collection.unsortedID
        let textures = UUID()
        let type = UUID()
        let folders = [
            collection("Unsorted", id: unsorted),
            collection("Textures", id: textures),
            collection("Type", id: type, parent: textures),
            collection("Serif", parent: type),
        ]
        let all = SwitcherRanking.candidates(
            folders: folders, unsortedID: unsorted, spaces: [], savedSearches: [])
        let detail = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0.detail) })

        #expect(detail["Home"] == "")
        #expect(detail["Unsorted"] == "Collections")
        #expect(detail["Textures"] == "Collections")
        #expect(detail["Type"] == "Textures")
        // Two levels down, so the path disambiguates rather than merely decorates —
        // which is the whole reason the switcher matches the LEAF NAME and shows the
        // path instead of matching the path.
        #expect(detail["Serif"] == "Textures ▸ Type")
    }

    @Test("typing a parent's name does not drag its subtree in")
    func onlyTheTitleIsMatched() {
        let unsorted = Collection.unsortedID
        let textures = UUID()
        let folders = [
            collection("Unsorted", id: unsorted),
            collection("Textures", id: textures),
            collection("Concrete", parent: textures),
            collection("Plaster", parent: textures),
        ]
        let all = SwitcherRanking.candidates(
            folders: folders, unsortedID: unsorted, spaces: [], savedSearches: [])
        let results = SwitcherRanking.results(for: "textures", in: all)
        #expect(results.map(\.candidate.title) == ["Textures"])
    }

    @Test("spaces and saved searches are destinations, and carry their own glyphs")
    func spacesAndSavedSearchesAreCandidates() {
        let spaceID = UUID()
        let searchID = UUID()
        let all = SwitcherRanking.candidates(
            folders: [collection("Unsorted", id: Collection.unsortedID)],
            unsortedID: Collection.unsortedID,
            spaces: [space("Moodboard", id: spaceID)],
            savedSearches: [savedSearch("Warm Tones", id: searchID)])

        let board = all.first { $0.destination == .space(spaceID) }
        #expect(board != nil, "the space is not a switcher candidate")
        #expect(board?.title == "Moodboard")
        #expect(board?.detail == "Spaces")
        let search = all.first { $0.destination == .savedSearch(searchID) }
        #expect(search != nil, "the saved search is not a switcher candidate")
        #expect(search?.title == "Warm Tones")
        #expect(search?.detail == "Smart")
        // The sidebar's own glyph for a saved search — the switcher is a shortcut
        // for that list and has to look like it.
        #expect(search?.symbol == "line.3.horizontal.decrease.circle")
    }

    @Test("spaces arrive in SpaceTargets order, not the order they were handed in")
    func spacesUseTheSharedSpaceOrdering() {
        let first = space("Second", index: 1)
        let second = space("First", index: 0)
        let all = SwitcherRanking.candidates(
            folders: [], unsortedID: Collection.unsortedID,
            spaces: [first, second], savedSearches: [])
        #expect(all.map(\.title) == ["Home", "Capture", "Archived", "First", "Second"])
    }

    @Test("Settings and the debug theme pane are not destinations")
    func nonDestinationsAreAbsent() {
        let all = SwitcherRanking.candidates(
            folders: [], unsortedID: Collection.unsortedID, spaces: [], savedSearches: [])
        #expect(!all.contains { $0.title == "Settings" })
        #expect(!all.contains { $0.title == "Theme" })
        #expect(all.count == 3)
    }
}
