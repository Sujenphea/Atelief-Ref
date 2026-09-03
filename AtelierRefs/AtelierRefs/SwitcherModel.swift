//
//  SwitcherModel.swift
//  AtelierRefs
//
//  099 · P5 — **the ⌘K quick switcher's brain**, and the answer to 011 · U4's open
//  question: *its own surface, the shared ordering.*
//
//  [024] · K3 left a note in `DestinationPicker.swift` saying the type-ahead
//  machinery was "deliberately NOT built here", and it was right to: that picker
//  files ASSETS into a collection, and a filter field on it would have been a
//  second feature riding a first one's popover. A switcher is the other verb — it
//  MOVES YOU — so it is its own surface. What it is not allowed to be is a second
//  opinion about what the destinations are or what order they come in: the
//  candidates below are built from ``CollectionTargets/destinationTree``,
//  ``SpaceTargets/ordered`` and the saved-search list the sidebar already draws,
//  in the sidebar's own top-to-bottom order.
//
//  **Verbs are not in v1.** "New Space" and "Snapshot Now" would be the obvious
//  next rows, and they are deliberately absent: both already have menu items with
//  key equivalents (⌘N through `NewItemCommand`, File ▸ Snapshot Now through
//  `SnapshotCommands`), so a switcher row would be a third spelling of a binding
//  that is already discoverable in two places — and the first one that took an
//  argument would need a whole second mode. The day a verb has no menu home, this
//  is where it goes.
//
//  Everything in this file is pure or trivially observable, which is the point:
//  the ranking is the feature, and a ranking asserted only through a UI flow is a
//  ranking nobody can change safely.
//

import AtelierBrowse
import AtelierCore
import Combine
import Foundation

// MARK: - A candidate

/// One place ⌘K can take you.
///
/// The destination is a ``SidebarItem`` rather than a switcher-private enum, so
/// there is exactly one vocabulary for "a top-level place" in the app and the
/// commit path is `NavModel.selectSidebar` with nothing to translate.
nonisolated struct SwitcherCandidate: Equatable, Identifiable, Sendable {
    /// Where selecting this row goes.
    let destination: SidebarItem
    /// What the user types against — and ONLY this. See ``SwitcherRanking/rank(_:matching:)``.
    let title: String
    /// The row's second line: a nested collection's ancestor path, else the
    /// sidebar section the row lives in. Empty for the three fixed destinations,
    /// which are their own section and would only repeat themselves.
    let detail: String
    /// The row's glyph — the same symbol the sidebar draws for this destination,
    /// so the switcher looks like the list it is a shortcut for.
    let symbol: String

    var id: SidebarItem { destination }
}

// MARK: - The ranking

/// How well a candidate's title answers a query. **Lower is better.**
///
/// Three tiers and no fourth. A subsequence ("fzf") tier is deliberately not
/// built: 099 · P5 names exactly these three, and a fourth would change which
/// rows appear at all rather than only their order — a bigger promise than this
/// phase was given, and one no test here could hold steady.
nonisolated enum SwitcherRank: Int, Comparable, Hashable, Sendable, CaseIterable {
    /// The title STARTS with the query. `co` → `Concrete`.
    case prefix = 0
    /// A word inside the title starts with the query. `con` → `Warm Concrete`,
    /// and also `mid-Concrete` — a word boundary is any character that is neither
    /// a letter nor a digit, so `/`, `-`, `_` and `(` all start a word.
    case wordStart = 1
    /// The query appears somewhere in the title, mid-word. `ncr` → `Concrete`.
    case substring = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One candidate that matched, and how well.
nonisolated struct SwitcherMatch: Equatable, Identifiable, Sendable {
    let candidate: SwitcherCandidate
    let rank: SwitcherRank

    var id: SidebarItem { candidate.destination }
    var destination: SidebarItem { candidate.destination }
}

/// The switcher's pure half: what the candidates are, how a query scores them,
/// and what order the results come back in.
///
/// # The ranking, in full
///
/// Results are sorted by three keys, in this order:
///
///  1. **Tier** — ``SwitcherRank/prefix`` before ``SwitcherRank/wordStart``
///     before ``SwitcherRank/substring``. A candidate matching none of the three
///     is not a result at all.
///  2. **Recents** — within a tier, a destination in the MRU comes before one
///     that is not, most recently visited first. (``SwitcherRecents``.)
///  3. **The shared ordering** — ties fall back to the candidate's position in
///     ``candidates(folders:unsortedID:spaces:savedSearches:)``, which is the
///     sidebar's own top-to-bottom order: the three fixed destinations, then
///     Spaces, then Smart, then the collection tree.
///
/// **An empty query is a prefix of everything**, which is not a special case so
/// much as the reason there is no special case: with every candidate at tier
/// `prefix`, the resting list falls out of the same sort as recents-first, then
/// the sidebar's order. One code path, and the resting list is testable with the
/// same function as a typed one.
///
/// **Only the title is matched.** A nested collection's ancestor path is shown so
/// two `Inspiration`s under different parents can be told apart, but typing a
/// parent's name deliberately does NOT drag its whole subtree in — a switcher that
/// answers `Textures` with eleven rows has stopped being a switcher.
nonisolated enum SwitcherRanking {

    /// The most rows the panel will offer. Applied AFTER the sort, so a cap can
    /// only ever drop the worst matches; a query that matches 300 collections
    /// still shows the best 40 of them, in the order above.
    static let resultLimit = 40

    // MARK: Candidates

    /// Every destination ⌘K can reach, in the shared ordering.
    ///
    /// The three fixed rows first (they are the sidebar's first three), then
    /// Spaces, then Smart, then the collections tree — which is the sidebar read
    /// top to bottom. Settings is not here for ``SidebarItem``'s reason: it is a
    /// window, not a destination. The DEBUG theme pane is not here either — a
    /// developer surface with a sidebar row of its own does not need a second door.
    static func candidates(
        folders: [Collection],
        unsortedID: UUID,
        spaces: [Space],
        savedSearches: [SavedSearch]
    ) -> [SwitcherCandidate] {
        var out: [SwitcherCandidate] = [
            SwitcherCandidate(
                destination: .home, title: "Home", detail: "", symbol: "house"),
            SwitcherCandidate(
                destination: .capture, title: "Capture", detail: "",
                symbol: "puzzlepiece.extension"),
            // "Archived" is the user's word for the shelf; `Shelf` is only the
            // code's (`SidebarView.navSection` says the same thing).
            SwitcherCandidate(
                destination: .shelf, title: "Archived", detail: "", symbol: "archivebox"),
        ]
        out += SpaceTargets.ordered(spaces).map {
            SwitcherCandidate(
                destination: .space($0.id), title: $0.name, detail: "Spaces",
                symbol: "square.on.square.dashed")
        }
        out += savedSearches.map {
            SwitcherCandidate(
                destination: .savedSearch($0.id), title: $0.name, detail: "Smart",
                symbol: "line.3.horizontal.decrease.circle")
        }
        out += collectionCandidates(
            CollectionTargets.destinationTree(folders: folders, unsortedID: unsortedID),
            unsortedID: unsortedID, ancestors: [])
        return out
    }

    /// The collection tree, pre-order, each row carrying its ancestors' names as
    /// its detail line. A root's detail is the section name instead, so every row
    /// in the list has a second line and the column does not go ragged.
    private static func collectionCandidates(
        _ nodes: [DestinationTreeNode], unsortedID: UUID, ancestors: [String]
    ) -> [SwitcherCandidate] {
        nodes.flatMap { node -> [SwitcherCandidate] in
            let candidate = SwitcherCandidate(
                destination: .collection(node.collection.id),
                title: node.collection.name,
                detail: ancestors.isEmpty ? "Collections" : ancestors.joined(separator: " ▸ "),
                symbol: node.collection.id == unsortedID ? "tray" : "folder")
            return [candidate] + collectionCandidates(
                node.children, unsortedID: unsortedID,
                ancestors: ancestors + [node.collection.name])
        }
    }

    // MARK: Matching

    /// Score one title against one query, or `nil` if it does not match at all.
    ///
    /// Case- and diacritic-insensitive on both sides, so `cafe` finds `Café` and
    /// `CAFÉ` finds `café`. An empty (or whitespace-only) query is a
    /// ``SwitcherRank/prefix`` of every title — see the type's note on why that is
    /// the absence of a special case rather than one.
    static func rank(_ title: String, matching query: String) -> SwitcherRank? {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return .prefix }
        let hay = fold(title)
        guard !hay.isEmpty else { return nil }

        var best: SwitcherRank?
        var from = hay.startIndex
        while from < hay.endIndex,
              let found = hay.range(of: needle, range: from..<hay.endIndex) {
            // Nothing beats starting the string, so the first occurrence settles it.
            if found.lowerBound == hay.startIndex { return .prefix }
            if isWordBoundary(hay[hay.index(before: found.lowerBound)]) {
                // Past index 0, nothing beats starting a word either.
                return .wordStart
            }
            best = .substring
            from = hay.index(after: found.lowerBound)
        }
        return best
    }

    /// The results for `query`, sorted by the ranking documented on this type.
    ///
    /// - Parameters:
    ///   - recents: the MRU, most recent first — ``SwitcherRecents/destinations``.
    ///   - limit: the cap, applied after sorting.
    static func results(
        for query: String,
        in candidates: [SwitcherCandidate],
        recents: [SidebarItem] = [],
        limit: Int = resultLimit
    ) -> [SwitcherMatch] {
        // `firstIndex(of:)` per candidate would be O(n·m); the MRU is capped at
        // eight but the candidate list is not, and this runs on every keystroke.
        var recency: [SidebarItem: Int] = [:]
        for (index, item) in recents.enumerated() where recency[item] == nil {
            recency[item] = index
        }

        struct Scored {
            let match: SwitcherMatch
            let recency: Int
            let order: Int
        }

        let scored = candidates.enumerated().compactMap { order, candidate -> Scored? in
            guard let rank = rank(candidate.title, matching: query) else { return nil }
            return Scored(
                match: SwitcherMatch(candidate: candidate, rank: rank),
                recency: recency[candidate.destination] ?? Int.max,
                order: order)
        }

        return scored
            .sorted { a, b in
                if a.match.rank != b.match.rank { return a.match.rank < b.match.rank }
                if a.recency != b.recency { return a.recency < b.recency }
                return a.order < b.order
            }
            .prefix(limit)
            .map(\.match)
    }

    // MARK: The two primitives the tiers are made of

    /// Case- and diacritic-folded, with an explicit `nil` locale so a machine in a
    /// Turkish locale ranks `I` the same way the tests' machine does.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whether `character` ENDS a word, so what follows it starts one.
    ///
    /// Anything that is not a letter or a digit: space, `-`, `_`, `/`, `.`, `(`,
    /// `&`, an emoji. Deliberately NOT a camel-case boundary — collection names in
    /// this app are prose the user typed ("Warm Tones", "Type / Serif"), and
    /// splitting `Textures` at nothing costs nothing while splitting `iOS` at the
    /// `O` would cost a wrong answer.
    static func isWordBoundary(_ character: Character) -> Bool {
        !(character.isLetter || character.isNumber)
    }
}

// MARK: - The MRU

/// The switcher's recently-visited list, persisted per library.
///
/// **The key is `library.<id>.switcherRecents`**, which is
/// ``ClipboardWatcher/enabledKey(libraryID:)``'s shape — `library.<id>.` per
/// 016 §C item 3. That discipline exists so multi-library needs no migration
/// later, and this is the second preference to adopt it rather than the first to
/// invent something.
///
/// A consequence the clipboard watcher already lives with applies here too: until
/// the library is open and its id resolves there is NO MRU, and the switcher falls
/// back to the shared ordering alone. That is the honest answer — a per-library
/// list cannot be read before we know which library we are in — and it costs a
/// first-launch user nothing they had.
@MainActor
final class SwitcherRecents {

    /// How many are kept. Small on purpose: the MRU's job is to put the two or
    /// three places you are moving between this afternoon at the top, and a long
    /// tail of them would only push the shared ordering out of reach.
    static let capacity = 8

    /// The per-library defaults key.
    nonisolated static func defaultsKey(libraryID: String) -> String {
        "library.\(libraryID).switcherRecents"
    }

    /// The library this list belongs to; `nil` until the library opens.
    private(set) var libraryID: String?

    /// The MRU, most recent first. Empty until ``activate(libraryID:)``.
    private(set) var destinations: [SidebarItem] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Bind to an open library and read its stored list.
    ///
    /// Tokens that no longer parse are dropped silently — a stored `theme` row
    /// from a debug build, or a hand-edited plist. A malformed MRU is not worth an
    /// error path; the worst it can do is order a list.
    func activate(libraryID: String) {
        self.libraryID = libraryID
        let stored = defaults.stringArray(forKey: Self.defaultsKey(libraryID: libraryID)) ?? []
        destinations = Array(stored.compactMap(Self.destination(forToken:)).prefix(Self.capacity))
    }

    /// Record a visit — most recent first, de-duplicated, capped.
    ///
    /// A no-op before the library id resolves, deliberately: writing to an
    /// un-namespaced key "for now" is exactly the migration 016 §C exists to avoid.
    func record(_ destination: SidebarItem) {
        guard let libraryID, Self.token(for: destination) != nil else { return }
        destinations = [destination] + destinations.filter { $0 != destination }
        if destinations.count > Self.capacity {
            destinations = Array(destinations.prefix(Self.capacity))
        }
        defaults.set(
            destinations.compactMap(Self.token(for:)),
            forKey: Self.defaultsKey(libraryID: libraryID))
    }

    // MARK: Tokens

    /// A destination as a stored string, or `nil` for one that is not persistable.
    ///
    /// A `switch` with no `default`, so a new ``SidebarItem`` case has to decide
    /// whether ⌘K remembers it — the discipline ``SidebarItem/acceptsAssetDrops``
    /// established for the same enum.
    nonisolated static func token(for destination: SidebarItem) -> String? {
        switch destination {
        case .home: "home"
        case .capture: "capture"
        case .shelf: "shelf"
        case .collection(let id): "collection:\(id.uuidString)"
        case .space(let id): "space:\(id.uuidString)"
        case .savedSearch(let id): "savedSearch:\(id.uuidString)"
        #if DEBUG
        // The theme pane is a debug surface and is not a switcher candidate, so
        // it can never be recorded — but the case still has to be answered.
        case .theme: nil
        #endif
        }
    }

    /// The inverse of ``token(for:)``; `nil` for anything that does not parse.
    nonisolated static func destination(forToken token: String) -> SidebarItem? {
        switch token {
        case "home": return .home
        case "capture": return .capture
        case "shelf": return .shelf
        default: break
        }
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "collection": return .collection(id)
        case "space": return .space(id)
        case "savedSearch": return .savedSearch(id)
        default: return nil
        }
    }
}

// MARK: - The model the panel drives

/// The switcher's state: the query, the ranked results, and the keyboard cursor.
///
/// Thin by design — every decision it makes is one of ``SwitcherRanking``'s, and
/// the tests that matter are that type's. What lives here is the part that has to
/// be observable: a query the field binds to, and a cursor Return commits.
@MainActor
final class SwitcherModel: ObservableObject {

    /// What the user has typed. Setting it re-ranks; the panel binds a field to it.
    @Published var query: String = "" {
        didSet { refresh() }
    }

    /// The ranked results for ``query``.
    @Published private(set) var results: [SwitcherMatch] = []

    /// The row Return would go to. Seeded to the first result on every open and on
    /// every re-rank, so the panel is usable without touching an arrow key — the
    /// ``DestinationPicker`` rule, for the same reason.
    @Published private(set) var highlighted: SidebarItem?

    private(set) var candidates: [SwitcherCandidate] = []
    private var recents: [SidebarItem] = []

    init() {}

    /// Arm the model for one presentation.
    ///
    /// The query is cleared every time. A ⌘K that reopened on the last thing typed
    /// would make the FIRST keystroke of the next use append to a stale needle,
    /// which is the one way a switcher can send you somewhere you did not ask for.
    func open(candidates: [SwitcherCandidate], recents: [SidebarItem]) {
        self.candidates = candidates
        self.recents = recents
        // Assigned through the stored property so `didSet` does the re-rank; the
        // value is already "" on a fresh model, which would not fire it.
        query = ""
        refresh()
    }

    /// Walk the cursor, clamped at both ends — ``CollectionDestinationList/step(from:in:by:)``,
    /// which is the app's one cursor walk and now serves both keyboard lists.
    func move(_ delta: Int) {
        highlighted = CollectionDestinationList.step(
            from: highlighted, in: results.map(\.destination), by: delta)
    }

    /// Point the cursor at a specific row (a pointer hovering it, a click).
    func highlight(_ destination: SidebarItem) {
        guard results.contains(where: { $0.destination == destination }) else { return }
        highlighted = destination
    }

    /// What Return would commit, or `nil` when nothing matches.
    var commitTarget: SidebarItem? { highlighted }

    /// Re-rank, and keep the cursor somewhere real.
    ///
    /// The cursor survives a keystroke only if the row it was on survived it;
    /// otherwise it goes back to the top. Leaving it on a row that has been
    /// filtered out is how Return files into something invisible.
    private func refresh() {
        results = SwitcherRanking.results(for: query, in: candidates, recents: recents)
        if let highlighted, results.contains(where: { $0.destination == highlighted }) { return }
        highlighted = results.first?.destination
    }
}
