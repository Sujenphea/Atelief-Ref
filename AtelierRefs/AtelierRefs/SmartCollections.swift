//
//  SmartCollections.swift
//  AtelierRefs
//
//  099 · P4 — smart collections reach the app.
//
//  `SavedSearch` CRUD, `evaluate(rules:)` and `savedSearchMissingTags(id:)` have
//  been in AtelierCore since 015, fully migrated and covered by
//  `ServicesSavedSearchTests` — and until this file there was **not one reference
//  to any of them in the app target**. The feature existed and was unreachable.
//
//  What lives here is the app-side half that was missing, and only the parts that
//  are genuinely pure or genuinely stateful:
//
//   • ``SmartCollectionSort`` — 007's grid sort modes MINUS `.manual`, derived
//     from `SortMode.allCases` rather than hand-listed so a fourth mode cannot
//     appear in a collection's menu and silently miss this one
//     ([057](../../.docs/057-smart-collections-overview.md): a saved search has
//     no manual order).
//   • ``SmartCollectionBadge`` — 057's two badges (*references a deleted tag*,
//     *can't read this search*), as a value the sidebar row and the grid header
//     both render, so the two cannot describe the same search differently.
//   • ``SavedSearchesSidebarModel`` — the list, the badges, the four verbs and the
//     staged delete.
//
//  Shaped after ``ShelfController`` (023 · A2), which was shaped after
//  `DuplicateReviewController`, which was shaped after `LibraryStatsController`:
//  `@MainActor`, services handed in per call rather than held, a read seam a test
//  can drive, and an authoritative reload after every mutation. A fifth shape for
//  "a pane with a list and a verb" would be a fifth set of bugs.
//

import AtelierCore
import Combine
import Foundation
import SwiftUI
import os

// MARK: - Sort (057 — 007's modes minus `.manual`)

/// How a smart collection's grid is ordered.
///
/// A saved search is a QUERY, not a container: nothing is filed in it, so there is
/// no `manual_order` column for a drag to write and `.manual` is not on offer
/// (057). The remaining two are 007's, and they mean exactly what they mean in a
/// collection — which is why ``sortMode`` exists rather than a parallel vocabulary.
///
/// **``offered`` is derived, not typed out.** `SortMode` is `CaseIterable`, so a
/// mode added to 007 appears here automatically unless someone teaches
/// ``init(_:)`` to drop it — and `SmartCollectionSortTests` asserts the exclusion
/// is exactly `{ .manual }`. A hand-written list would have gone stale silently,
/// which is the failure mode 057's own "rule drift" risk names.
nonisolated enum SmartCollectionSort: String, CaseIterable, Hashable, Sendable {
    case newest
    case mostViewed

    /// The smart-collection sort for a grid ``SortMode``, or `nil` for the one
    /// mode a query cannot have.
    init?(_ mode: SortMode) {
        switch mode {
        case .manual: return nil
        case .newest: self = .newest
        case .mostViewed: self = .mostViewed
        }
    }

    /// The grid ``SortMode`` this is — the same mode a collection would store.
    var sortMode: SortMode {
        switch self {
        case .newest: .newest
        case .mostViewed: .mostViewed
        }
    }

    /// The menu's label — the same words the collection sort menu uses.
    var title: String {
        switch self {
        case .newest: "Newest"
        case .mostViewed: "Most Viewed"
        }
    }

    /// The menu's glyph, matching `CollectionView.sortMenu`'s.
    var symbol: String {
        switch self {
        case .newest: "clock"
        case .mostViewed: "eye"
        }
    }

    /// Every mode a smart collection offers, in 007's declaration order.
    static var offered: [SmartCollectionSort] { SortMode.allCases.compactMap(SmartCollectionSort.init) }

    /// The modes a smart collection deliberately does NOT offer — `[.manual]`, and
    /// the test says so out loud rather than assuming the compactMap dropped what
    /// it was meant to.
    static var excluded: [SortMode] { SortMode.allCases.filter { SmartCollectionSort($0) == nil } }
}

// MARK: - "Save this search…" (057 — the search field IS the rule editor)

/// What the search field's save control does when pressed.
///
/// 057 settles the creation UX and, in the same breath, the EDIT one: *"Save this
/// search" from [007]'s search UI (the search field state IS the rule editor — no
/// separate rule-builder UI in v1) + rename/edit-by-rerunning-and-resaving.* So the
/// control has two meanings and the destination decides which — pressing it while
/// a smart collection is open re-rules THAT search rather than making a second one
/// with a slightly different name, because "re-run and re-save" has no other way to
/// mean anything.
///
/// Pure and separate from the toolbar item so the decision is asserted rather than
/// read off a `ViewBuilder`.
nonisolated enum SaveSearchAction: Equatable {
    /// Nothing to save — the field is empty of text and tokens alike.
    case unavailable
    /// Save the live query as a NEW smart collection, prompting for a name.
    case save
    /// Replace this open smart collection's rules with the live query. No name
    /// prompt: it already has one, and asking again would invite two searches
    /// called the same thing.
    case update(id: UUID)
}

/// Decide what the save control does, from the two facts that settle it.
nonisolated func saveSearchAction(isActive: Bool, sidebar: SidebarItem) -> SaveSearchAction {
    guard isActive else { return .unavailable }
    if case .savedSearch(let id) = sidebar { return .update(id: id) }
    return .save
}

extension SaveSearchAction {
    /// The control's title. `update` names the search so the button cannot be
    /// mistaken for "save a new one" while one is open.
    func title(currentName: String?) -> String {
        switch self {
        case .unavailable, .save: "Save this search…"
        case .update: currentName.map { "Update “\($0)”" } ?? "Update this search"
        }
    }

    /// Whether the control is enabled — 057's "only when the query is non-empty".
    var isEnabled: Bool { self != .unavailable }
}

// MARK: - Badges (057)

/// Why a smart collection needs saying something about, on the sidebar row and on
/// the grid header alike.
///
/// 057 names both, and both are "explicit over silently-empty": a rule that
/// references a tag the user has since deleted still runs — the surviving
/// conjuncts filter, the missing one is dropped (`AppServices.evaluate(rules:)`) —
/// so without a badge the result set would just be quietly wider than the name
/// promises. A blob that will not decode at all cannot run, and an empty grid with
/// no explanation reads as "nothing matches" rather than "I could not read this".
///
/// One value, rendered by two surfaces, so the row and the header cannot describe
/// the same search differently — the `316` "two lists, one of them unseen" rule.
nonisolated enum SmartCollectionBadge: Equatable, Hashable, Sendable {
    /// The rule names `count` tag ids that are no longer real tags
    /// (`AppServices.savedSearchMissingTags(id:)`). The search still runs.
    case missingTags(count: Int)
    /// `saved_search.rules` will not decode — `AtelierError.invalidSavedSearchRules`.
    /// The search cannot run at all.
    case unreadableRules

    /// The SF Symbol the row and the header draw.
    var symbol: String {
        switch self {
        case .missingTags: "tag.slash"
        case .unreadableRules: "exclamationmark.triangle"
        }
    }

    /// The short sentence — a tooltip on the row, a caption on the header.
    var sentence: String {
        switch self {
        case .missingTags(let count):
            count == 1
                ? "References a deleted tag; that filter is skipped."
                : "References \(count) deleted tags; those filters are skipped."
        case .unreadableRules:
            "Can't read this search — its saved rules are unreadable."
        }
    }

    /// Whether the search can still return results. An unreadable rule cannot;
    /// a dropped tag conjunct only widens the answer.
    var stillRuns: Bool {
        switch self {
        case .missingTags: true
        case .unreadableRules: false
        }
    }
}

// MARK: - The sidebar / gallery list model

/// The app's view of every saved search: the list, each one's badge, and the four
/// verbs (create, rename, re-rule, delete).
///
/// **It holds no services.** They arrive per call, as `ShelfController`'s do, so
/// this object is constructible before the Library is open and a test can drive it
/// against a temporary one. Every mutation reloads authoritatively rather than
/// patching the published array: this surface changes underneath itself (a tag
/// delete moves a badge, a re-save moves a rule) and a patched list would offer
/// verbs on rows that no longer say what they said.
@MainActor
final class SavedSearchesSidebarModel: ObservableObject {

    /// Every saved search, newest first — `AppServices.savedSearches()`' order,
    /// unchanged. Flat: 057 · open question 2 recommends no nesting until it
    /// hurts, and nothing since has said it hurts.
    @Published private(set) var searches: [SavedSearch] = []

    /// The badge for each search that has one (057). Absent = nothing to say,
    /// which is the overwhelming majority.
    @Published private(set) var badges: [UUID: SmartCollectionBadge] = [:]

    /// Whether the list has been read at least once this session. `searches`
    /// being empty is otherwise indistinguishable from "not read yet", and the
    /// sidebar must not say "No smart collections" about a list it has not seen —
    /// the three-state rule `ShelfController.hasLoaded` exists for.
    @Published private(set) var hasLoaded = false

    /// Why the last read or verb failed, in words; `nil` when all is well.
    @Published var lastError: String?

    /// A staged delete awaiting the shared confirmation, or `nil`.
    ///
    /// Deleting a smart collection deletes the QUERY only and never touches an
    /// asset (057), so there is no undo entry to register — but it is still a
    /// thing the user cannot get back by pressing ⌘Z, which is exactly what the
    /// app's other irreversible verbs confirm first.
    @Published var pendingDeletion: PendingDeletion?

    /// The saved search staged for a confirmed delete.
    struct PendingDeletion: Equatable {
        let id: UUID
        let name: String
    }

    private let log = Logger(subsystem: "com.atelier.refs", category: "smart-collections")

    /// How the list is actually read. Overridable exactly as
    /// ``ShelfController/readShelf`` is, and for the same reason: unread-vs-empty
    /// -vs-failed cannot be provoked against a real database on demand, and the
    /// branch that matters most (a failed refresh must NOT blank the list) would
    /// otherwise go unasserted.
    var readSearches: (AppServices) async throws -> [SavedSearch] = {
        try await $0.savedSearches()
    }

    /// How a badge is resolved for one search. Split from ``readSearches`` because
    /// it is per-row and N+1 by nature — see ``load(services:)`` for why that is
    /// acceptable here and would not be on a grid.
    var readBadge: (AppServices, SavedSearch) async throws -> SmartCollectionBadge? = { services, search in
        // An undecodable blob is answered locally: `savedSearchMissingTags` returns
        // `[]` for it (nothing tag-specific to report), so asking the service would
        // give the same answer as a healthy rule with no tags.
        guard search.decodedRules != nil else { return .unreadableRules }
        let missing = try await services.savedSearchMissingTags(id: search.id)
        return missing.isEmpty ? nil : .missingTags(count: missing.count)
    }

    /// Issue counter, so the NEWEST read wins rather than the last-arriving one —
    /// `ShelfController`'s ticket, for the same reason: the sidebar reloads on
    /// appear, on a navigation pulse and after every verb, so overlapping reads
    /// are the normal case and `await` does not preserve issue order.
    private var loadSeq = 0

    /// Load lifecycle, for tests that must await a reload rather than guess at one
    /// (099 · 11A). Nothing in the app subscribes.
    let events = EventSignal<Event>()

    /// What one load did. The LIFECYCLE, not the answer — a test that awaits
    /// `.superseded` proves the ticket held, which "the list is what I expected"
    /// cannot.
    nonisolated enum Event: Sendable, Equatable {
        /// A load published `count` searches.
        case loaded(count: Int)
        /// A load finished but a newer one had already started, so it published
        /// nothing.
        case superseded
        /// A load threw; ``lastError`` carries the sentence and the previous list
        /// is still standing.
        case failed
    }

    init() {}

    // MARK: - Reading

    /// How many smart collections there are — the section header's count.
    var count: Int { searches.count }

    /// True only when the list has been READ and is genuinely empty.
    var isEmpty: Bool { hasLoaded && searches.isEmpty }

    /// The search with `id`, or `nil` — what a header asks for its title.
    func search(id: UUID) -> SavedSearch? { searches.first { $0.id == id } }

    /// The badge for `id`, or `nil`.
    func badge(id: UUID) -> SmartCollectionBadge? { badges[id] }

    /// Re-read every saved search and its badge, authoritatively.
    ///
    /// **The badge pass is one query per search, and that is deliberate.**
    /// `savedSearchMissingTags` is an `IN` over the rule's own tag ids — a handful
    /// of rows against a table with a primary-key index — and the saved-search
    /// table is small by construction (015: "the table is small, so this is an
    /// unpaged list"). Batching it would mean a second service call that exists
    /// only for a badge; the moment this list is big enough for that to matter,
    /// 057 · open question 2's "flat until it hurts" has already been answered.
    func load(services: AppServices) async {
        loadSeq &+= 1
        let ticket = loadSeq
        do {
            let fetched = try await readSearches(services)
            // A newer read was issued while this one was in flight — its answer is
            // the one that should land.
            guard ticket == loadSeq else { events.emit(.superseded); return }
            searches = fetched
            hasLoaded = true
            lastError = nil
            var resolved: [UUID: SmartCollectionBadge] = [:]
            for search in fetched {
                guard let badge = try await readBadge(services, search) else { continue }
                resolved[search.id] = badge
            }
            guard ticket == loadSeq else { events.emit(.superseded); return }
            badges = resolved
            events.emit(.loaded(count: fetched.count))
        } catch {
            guard ticket == loadSeq else { events.emit(.superseded); return }
            // The previous `searches` are LEFT in place. A failed refresh means "I
            // could not check", not "you have none", and blanking the section would
            // say the second.
            lastError = ErrorMessage.text(for: error)
            log.error("saved-search load failed: \(error.localizedDescription, privacy: .public)")
            events.emit(.failed)
        }
    }

    // MARK: - The verbs

    /// Run one write, then reload authoritatively — and let the WRITE have the
    /// last word on ``lastError``.
    ///
    /// The order matters and it is the whole reason this helper exists. A verb that
    /// set its sentence and then reloaded had it wiped by the reload's own
    /// `lastError = nil` on success, so a rejected rename reported nothing at all
    /// while quietly not renaming anything. The reload still happens — the list is
    /// the database's, whatever the verb did — and the failure is re-stated after it.
    private func perform(
        _ verb: String, on services: AppServices, _ body: () async throws -> Void
    ) async {
        var failure: String?
        do {
            try await body()
        } catch {
            failure = ErrorMessage.text(for: error)
            let detail = error.localizedDescription
            log.error("saved-search \(verb, privacy: .public) failed: \(detail, privacy: .public)")
        }
        await load(services: services)
        if let failure { lastError = failure }
    }

    /// Save the live query as a new smart collection (057 · "Save this search").
    /// Returns the created search, or `nil` when the write failed.
    @discardableResult
    func create(name: String, rules: SearchRules, services: AppServices) async -> SavedSearch? {
        var created: SavedSearch?
        await perform("create", on: services) {
            created = try await services.createSavedSearch(name: name, rules: rules)
        }
        return created
    }

    /// Rename one — the inline sidebar edit's commit.
    func rename(id: UUID, to name: String, services: AppServices) async {
        await perform("rename", on: services) {
            _ = try await services.renameSavedSearch(id: id, to: name)
        }
    }

    /// Replace one's rules — the "re-run and re-save" edit (057: the search field
    /// IS the rule editor, so this is what re-saving from an open smart collection
    /// does rather than making a second search with the same name).
    func updateRules(id: UUID, rules: SearchRules, services: AppServices) async {
        await perform("re-rule", on: services) {
            _ = try await services.updateSavedSearchRules(id: id, rules: rules)
        }
    }

    /// Stage a delete for the shared confirmation.
    func requestDelete(id: UUID, name: String) {
        pendingDeletion = PendingDeletion(id: id, name: name)
    }

    /// Dismiss the staged delete without acting.
    func cancelDelete() { pendingDeletion = nil }

    /// Carry out the confirmed delete. The query only — a saved search has no FK
    /// to an asset or a tag (its tag ids live inside the rules JSON), so this can
    /// never cascade a single picture away (057).
    func confirmDelete(services: AppServices) async {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        await perform("delete", on: services) {
            try await services.deleteSavedSearch(id: pending.id)
        }
    }
}
