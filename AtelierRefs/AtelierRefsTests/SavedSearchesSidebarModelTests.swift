//
//  SavedSearchesSidebarModelTests.swift
//  AtelierRefsTests
//
//  099 · P4 — the app's half of smart collections.
//
//  `SavedSearch` CRUD and `evaluate(rules:)` have been covered in
//  `AtelierCoreTests/ServicesSavedSearchTests` since 015 and are not re-tested
//  here. What is new — and what had no test anywhere, because it had no code
//  anywhere — is everything between those services and a window: the list, the
//  badges, the two sort modes a query is allowed to have, the four verbs, what
//  "Save this search…" means when a smart collection is already open, and what
//  happens to the route when the one you are looking at is deleted.
//
//  The read seams (``SavedSearchesSidebarModel/readSearches`` /
//  ``SavedSearchesSidebarModel/readBadge``) are overridden where the state under
//  test cannot be provoked against a real database on demand — a failed refresh,
//  and one read overtaking another — for `ShelfController`'s reason: the branch
//  that matters most (a failed read must NOT blank the list) would otherwise go
//  unasserted. Everything else runs against a real temporary library.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Smart collections: the list, the badges, the verbs (099 · P4 / 057)",
       .timeLimit(.minutes(1)))
struct SavedSearchesSidebarModelTests {

    // MARK: - Fixtures

    private func makeServices(_ label: String) throws -> AppServices {
        let path = NSTemporaryDirectory() + "smart-\(label)-\(UUID().uuidString).sqlite"
        return try AppServices(databasePath: path)
    }

    @discardableResult
    private func ingestColor(
        _ services: AppServices, _ hex: String, into collectionID: UUID,
        title: String? = nil
    ) async throws -> Asset {
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(hex)", title: title,
            capturedAt: Date())
        return try await services.ingestContent(
            .color(hex: hex), from: source, into: collectionID).asset
    }

    // MARK: - The list

    @Test("the list is the service's — newest first — and `hasLoaded` says so")
    func listsNewestFirst() async throws {
        let services = try makeServices("list")
        let model = SavedSearchesSidebarModel()

        // Before the first read, an empty list is NOT an answer.
        #expect(model.searches.isEmpty)
        #expect(!model.hasLoaded)
        #expect(!model.isEmpty)

        let first = try await services.createSavedSearch(
            name: "Serif", rules: SearchRules(text: "serif"))
        let second = try await services.createSavedSearch(
            name: "Teal", rules: SearchRules(text: "teal"))

        await model.load(services: services)
        #expect(model.hasLoaded)
        #expect(model.count == 2)
        // `savedSearches()` orders `created_at DESC, id DESC`.
        #expect(model.searches.map(\.id) == [second.id, first.id])
        #expect(model.search(id: first.id)?.name == "Serif")
        #expect(model.search(id: UUID()) == nil)
    }

    @Test("a read that has happened and found nothing IS an empty smart list")
    func loadedAndEmpty() async throws {
        let services = try makeServices("empty")
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)
        #expect(model.hasLoaded)
        #expect(model.isEmpty)
    }

    @Test("a failed refresh keeps the previous list rather than blanking it")
    func failedLoadKeepsTheList() async throws {
        let services = try makeServices("fail")
        _ = try await services.createSavedSearch(name: "Serif", rules: SearchRules())
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)
        #expect(model.count == 1)

        struct Boom: Error {}
        model.readSearches = { _ in throw Boom() }
        await model.load(services: services)

        // "I could not check" is not "you have none".
        #expect(model.count == 1)
        #expect(model.lastError != nil)
        #expect(model.hasLoaded)
    }

    // MARK: - Rename

    @Test("rename writes through the service and the list reflects it")
    func renameWritesAndReloads() async throws {
        let services = try makeServices("rename")
        let search = try await services.createSavedSearch(
            name: "Serif", rules: SearchRules(text: "serif"))
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)

        await model.rename(id: search.id, to: "Serif refs", services: services)
        #expect(model.search(id: search.id)?.name == "Serif refs")
        // The RULES are untouched by a rename — 057 keeps the two edits separate.
        #expect(model.search(id: search.id)?.decodedRules?.text == "serif")
    }

    @Test("a rejected rename surfaces a sentence and leaves the name alone")
    func renameRejected() async throws {
        let services = try makeServices("rename-bad")
        let search = try await services.createSavedSearch(name: "Serif", rules: SearchRules())
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)

        await model.rename(id: search.id, to: "   ", services: services)
        #expect(model.search(id: search.id)?.name == "Serif")
        #expect(model.lastError == AtelierError.invalidName.localizedDescription)
    }

    // MARK: - The rules edit (057 — the search field IS the rule editor)

    @Test("re-ruling replaces the rules, keeps the name, and moves updatedAt")
    func updateRulesKeepsTheName() async throws {
        let services = try makeServices("rerule")
        let search = try await services.createSavedSearch(
            name: "Serif", rules: SearchRules(text: "serif"))
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)
        let before = try #require(model.search(id: search.id)?.updatedAt)

        await model.updateRules(
            id: search.id, rules: SearchRules(text: "grotesk", favoritesOnly: true),
            services: services)

        let after = try #require(model.search(id: search.id))
        #expect(after.name == "Serif")
        #expect(after.decodedRules?.text == "grotesk")
        #expect(after.decodedRules?.favoritesOnly == true)
        #expect(after.updatedAt >= before)
    }

    // MARK: - Delete

    @Test("delete is staged, confirmed, and takes the QUERY only")
    func deleteStagesAndTakesOnlyTheQuery() async throws {
        let services = try makeServices("delete")
        let collection = try await services.createCollection(name: "Refs")
        try await ingestColor(services, "#112233", into: collection.id)
        try await ingestColor(services, "#445566", into: collection.id)
        let search = try await services.createSavedSearch(name: "All", rules: SearchRules())
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)

        model.requestDelete(id: search.id, name: search.name)
        #expect(model.pendingDeletion == .init(id: search.id, name: "All"))
        // Staging alone writes nothing.
        #expect(model.count == 1)

        await model.confirmDelete(services: services)
        #expect(model.pendingDeletion == nil)
        #expect(model.isEmpty)
        // 057: deleting a smart collection deletes the query and nothing else.
        let survivors = try await services.collectionItems(
            in: collection.id, sort: .newest, includeArchived: false)
        #expect(survivors.count == 2)
    }

    @Test("cancelling a staged delete leaves the search alone")
    func cancelDeleteLeavesIt() async throws {
        let services = try makeServices("delete-cancel")
        let search = try await services.createSavedSearch(name: "All", rules: SearchRules())
        let model = SavedSearchesSidebarModel()
        await model.load(services: services)

        model.requestDelete(id: search.id, name: search.name)
        model.cancelDelete()
        #expect(model.pendingDeletion == nil)

        await model.confirmDelete(services: services)   // nothing staged → no-op
        await model.load(services: services)
        #expect(model.count == 1)
    }

    // MARK: - Badges (057)

    @Test("a rule naming a tag that no longer exists badges the row")
    func badgeForMissingTag() async throws {
        let services = try makeServices("badge-tag")
        let collection = try await services.createCollection(name: "Refs")
        let asset = try await ingestColor(services, "#112233", into: collection.id)
        let live = try await services.applyTag("ui", to: asset.id, source: .user)
        // One live tag and one id no tag row has ever carried.
        let search = try await services.createSavedSearch(
            name: "UI", rules: SearchRules(tagIDs: [live.id, UUID()], tagMatch: .any))

        let model = SavedSearchesSidebarModel()
        await model.load(services: services)
        #expect(model.badge(id: search.id) == .missingTags(count: 1))
        // The search still RUNS — the surviving conjunct filters, the missing one
        // is dropped, which is 057's "explicit over silently-empty".
        #expect(model.badge(id: search.id)?.stillRuns == true)
    }

    @Test("a rule whose tags are all live carries no badge")
    func noBadgeWhenEveryTagIsLive() async throws {
        let services = try makeServices("badge-none")
        let collection = try await services.createCollection(name: "Refs")
        let asset = try await ingestColor(services, "#112233", into: collection.id)
        let live = try await services.applyTag("ui", to: asset.id, source: .user)
        let search = try await services.createSavedSearch(
            name: "UI", rules: SearchRules(tagIDs: [live.id]))

        let model = SavedSearchesSidebarModel()
        await model.load(services: services)
        #expect(model.badge(id: search.id) == nil)
    }

    @Test("a rule blob that will not decode badges as unreadable, and cannot run")
    func badgeForUnreadableRules() async throws {
        let services = try makeServices("badge-blob")
        let search = try await services.createSavedSearch(name: "Broken", rules: SearchRules())
        let model = SavedSearchesSidebarModel()
        // The stored blob is opaque TEXT, so a corrupt one is reachable only by
        // handing the model a row with one. That is exactly what a far-future or a
        // hand-edited `saved_search.rules` looks like from here.
        var corrupt = search
        corrupt.rules = "{ this is not json"
        model.readSearches = { _ in [corrupt] }
        await model.load(services: services)

        #expect(model.badge(id: search.id) == .unreadableRules)
        // It cannot RUN, which is the difference from a dropped tag conjunct: the
        // grid gets `.invalidSavedSearchRules` from `evaluateSavedSearch`, not an
        // empty page that would read as "nothing matches".
        #expect(model.badge(id: search.id)?.stillRuns == false)
        #expect(corrupt.decodedRules == nil)
        // …and a search that is not there at all is the OTHER error the feed owns.
        await #expect(throws: AtelierError.self) {
            _ = try await services.evaluateSavedSearch(id: UUID(), limit: 10)
        }
    }

    @Test("both badges say something, and say different things")
    func badgeSentences() {
        #expect(SmartCollectionBadge.missingTags(count: 1).sentence
                != SmartCollectionBadge.missingTags(count: 2).sentence)
        #expect(!SmartCollectionBadge.unreadableRules.sentence.isEmpty)
        #expect(SmartCollectionBadge.unreadableRules.symbol
                != SmartCollectionBadge.missingTags(count: 1).symbol)
    }

    // MARK: - Reconcile on delete (the route)

    @Test("deleting the OPEN smart collection falls the route back to Home")
    func reconcileOnDelete() {
        let gone = UUID()
        let kept = SavedSearch(
            id: UUID(), name: "Kept", rules: "{}", createdAt: Date(), updatedAt: Date())
        let nav = NavModel(initialPath: [], initialSelection: .savedSearch(gone))

        nav.reconcileSavedSearches(using: [kept], hasLoaded: true)
        #expect(nav.sidebarSelection == .home)
    }

    @Test("deleting the LAST smart collection falls back too — zero is an answer")
    func reconcileOnDeletingTheLast() {
        let gone = UUID()
        let nav = NavModel(initialPath: [], initialSelection: .savedSearch(gone))
        // `reconcile(using:)` can treat an empty COLLECTION list as "not loaded"
        // because the database always has Unsorted. A saved-search list has no such
        // floor, which is why `hasLoaded` is passed rather than inferred.
        nav.reconcileSavedSearches(using: [], hasLoaded: true)
        #expect(nav.sidebarSelection == .home)
    }

    @Test("a list that has not been read yet never moves the route")
    func reconcileIgnoresAnUnreadList() {
        let open = UUID()
        let nav = NavModel(initialPath: [], initialSelection: .savedSearch(open))
        nav.reconcileSavedSearches(using: [], hasLoaded: false)
        #expect(nav.sidebarSelection == .savedSearch(open))
    }

    @Test("a surviving smart collection is left exactly where it is")
    func reconcileLeavesALiveSelection() {
        let open = SavedSearch(
            id: UUID(), name: "Open", rules: "{}", createdAt: Date(), updatedAt: Date())
        let nav = NavModel(initialPath: [], initialSelection: .savedSearch(open.id))
        nav.reconcileSavedSearches(using: [open], hasLoaded: true)
        #expect(nav.sidebarSelection == .savedSearch(open.id))
    }

    @Test("the fallback only fires from a smart-collection route")
    func fallbackIsScoped() {
        let collection = UUID()
        let nav = NavModel(initialPath: [], initialSelection: .collection(collection))
        nav.fallBackFromSavedSearch()
        #expect(nav.sidebarSelection == .collection(collection))
    }

    // MARK: - Inline rename, through the shared edit state

    @Test("the sidebar's inline rename resolves through SidebarEditState's rules")
    func inlineRenameOutcomes() {
        let id = UUID()
        let edit = SidebarEditState(session: .rename(id: id), originalName: "Serif")
        #expect(edit.isRenaming(id))
        // A committed change renames…
        #expect(edit.outcome(committing: "Grotesk") == .rename(id: id, name: "Grotesk"))
        // …Escape, an empty name, and a name that did not change all write nothing,
        // which is why a rename cannot bump `updated_at` for free.
        #expect(edit.outcome(committing: nil) == .cancel)
        #expect(edit.outcome(committing: "   ") == .cancel)
        #expect(edit.outcome(committing: "Serif") == .cancel)
    }
}

// MARK: - Sort (057 — 007's modes minus `.manual`)

@Suite("Smart collections: the sort a query is allowed to have (057)")
struct SmartCollectionSortTests {

    @Test("the offered modes are exactly 007's, minus manual")
    func offeredIsSevenModesMinusManual() {
        #expect(SmartCollectionSort.offered.map(\.sortMode) == [.newest, .mostViewed])
        #expect(SmartCollectionSort.excluded == [.manual])
        // Derived, not hand-listed: a fourth `SortMode` lands in one of the two
        // lists above the day it is added, and this is the assertion that notices.
        #expect(SortMode.allCases.count
                == SmartCollectionSort.offered.count + SmartCollectionSort.excluded.count)
    }

    @Test("every mode round-trips through SortMode, and manual has no smart form")
    func roundTrip() {
        for mode in SmartCollectionSort.allCases {
            #expect(SmartCollectionSort(mode.sortMode) == mode)
        }
        #expect(SmartCollectionSort(.manual) == nil)
    }

    @Test("each mode has its own label and glyph")
    func labels() {
        let titles = Set(SmartCollectionSort.offered.map(\.title))
        let symbols = Set(SmartCollectionSort.offered.map(\.symbol))
        #expect(titles.count == SmartCollectionSort.offered.count)
        #expect(symbols.count == SmartCollectionSort.offered.count)
    }
}

// MARK: - "Save this search…" (the search model's save path)

@MainActor
@Suite("Smart collections: saving the live query (057 / 099 · 4A)")
struct SaveThisSearchTests {

    @Test("the control is dead while the query is empty")
    func unavailableWithAnEmptyQuery() {
        #expect(saveSearchAction(isActive: false, sidebar: .home) == .unavailable)
        #expect(saveSearchAction(isActive: false, sidebar: .savedSearch(UUID())) == .unavailable)
        #expect(!SaveSearchAction.unavailable.isEnabled)
    }

    @Test("a live query saves as a NEW smart collection from anywhere else")
    func savesFromAnywhereElse() {
        #expect(saveSearchAction(isActive: true, sidebar: .home) == .save)
        #expect(saveSearchAction(isActive: true, sidebar: .collection(UUID())) == .save)
        #expect(saveSearchAction(isActive: true, sidebar: .shelf) == .save)
        #expect(saveSearchAction(isActive: true, sidebar: .space(UUID())) == .save)
        #expect(SaveSearchAction.save.title(currentName: nil) == "Save this search…")
    }

    @Test("re-saving from an OPEN smart collection updates ITS rules (057)")
    func reSavingUpdatesTheOpenSearch() {
        let id = UUID()
        #expect(saveSearchAction(isActive: true, sidebar: .savedSearch(id)) == .update(id: id))
        #expect(SaveSearchAction.update(id: id).title(currentName: "Serif") == "Update “Serif”")
        // …and it still says something when the list has not caught up.
        #expect(!SaveSearchAction.update(id: id).title(currentName: nil).isEmpty)
    }

    /// The whole save path in one line of production code —
    /// `SearchRules(query: search.keywordQuery)` — asserted end to end, because it
    /// is where a field's transient state becomes a stored rule.
    @Test("the saved rule is every filter the field carries")
    func savedRuleIsTheFilters() async throws {
        let search = LibrarySearchModel()
        let tag = Tag(id: UUID(), name: "ui", source: .user)
        let collection = Collection(
            id: UUID(), name: "Refs", createdAt: Date(), updatedAt: Date())
        search.text = "serif"
        search.tokens = [.tag(tag), .collection(collection), .favorites, .color(.red)]

        let rules = SearchRules(query: search.keywordQuery)

        #expect(rules.text == "serif")
        #expect(rules.tagIDs == [tag.id])
        #expect(rules.collectionID == collection.id)
        #expect(rules.favoritesOnly)
        #expect(rules.colorBuckets == [ColorBucket.red.rawValue])
        // Stamped at the current version by the memberwise init, and again by the
        // service on write.
        #expect(rules.version == SearchRules.currentVersion)
    }

    /// The `tag:` directive is an INPUT METHOD, not a filter: it narrows the
    /// suggestion list until a token is picked. Saving it would persist a word
    /// nobody finished typing (`SearchRulesBridge`'s header, 044/045 · 17A).
    @Test("a half-typed `tag:` needle is not saved as text, and not saved at all")
    func theTagNeedleDoesNotCross() {
        let search = LibrarySearchModel()
        search.text = "tag:edit"

        // The live query carries the needle in its own field…
        let query = search.keywordQuery
        #expect(query.text.isEmpty)
        #expect(query.tagNameContains == "edit")

        // …and the stored rule has nowhere to put it, so the blob says nothing
        // about a tag at all rather than saying "edit".
        let rules = SearchRules(query: query)
        #expect(rules.text == nil)
        #expect(rules.tagIDs.isEmpty)
    }

    @Test("a `.meaning` query saves as its keyword filters, because a rule has no mode")
    func meaningQuerySavesItsFilters() async throws {
        let search = LibrarySearchModel()
        let tag = Tag(id: UUID(), name: "ui", source: .user)
        search.mode = .meaning
        search.text = "something calm"
        search.tokens = [.tag(tag)]

        let rules = SearchRules(query: search.keywordQuery)
        // `evaluate(rules:)` runs `searchAssets` — the keyword path — for every
        // saved search, so this is not a loss so much as the only thing a rule
        // could have meant.
        #expect(rules.text == "something calm")
        #expect(rules.tagIDs == [tag.id])
    }

    @Test("an empty field is not saveable, and `isActive` is the gate")
    func emptyFieldIsNotActive() {
        let search = LibrarySearchModel()
        #expect(!search.isActive)
        search.text = "   "
        #expect(!search.isActive)
        search.text = "serif"
        #expect(search.isActive)
        search.text = ""
        search.tokens = [.favorites]
        #expect(search.isActive)
    }
}
