// AtelierCore — AppServices: smart collections (the P0 file split).
//
// A saved search is a NAME plus a `SearchRules` blob; evaluating one is a
// `searchAssets` call with the rules unpacked into arguments. Moved verbatim out
// of `AppServices.swift` — same code, same order, same comments.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

import Foundation
import GRDB

extension AppServices {

    // MARK: - Smart collections (saved searches, 015)

    /// Create a smart collection — a named saved search (015). Validates + trims
    /// the name (C8); serializes `rules` to versioned JSON at the ``SearchRules``
    /// seam and stores it opaque; the service generates `id` and
    /// `createdAt`/`updatedAt` (server-authoritative). `rules` is stamped with the
    /// codec's current version on write.
    @discardableResult
    public func createSavedSearch(name: String, rules: SearchRules) async throws -> SavedSearch {
        let trimmed = try Validation.savedSearchName(name)
        // Re-stamp to the current shape version so a caller can't persist a rule
        // claiming a version it wasn't written as (the blob and its version agree).
        var stamped = rules
        stamped.version = SearchRules.currentVersion
        let json = try stamped.encoded()
        let now = Date()
        let search = SavedSearch(
            id: UUID(), name: trimmed, rules: json, createdAt: now, updatedAt: now)
        return try await write { db in
            try search.insert(db)
            return search
        }
    }

    /// Every saved search, newest first (`created_at DESC, id DESC` — deterministic
    /// tie-break). The table is small, so this is an unpaged list.
    public func savedSearches() async throws -> [SavedSearch] {
        try await read { db in
            try SavedSearch
                .order(Column("created_at").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    /// The saved search with `id`, or `nil` if absent.
    public func savedSearch(id: UUID) async throws -> SavedSearch? {
        try await read { db in
            try SavedSearch.fetchOne(db, key: Self.key(id))
        }
    }

    /// Rename a saved search; `.notFound` if absent; bumps `updatedAt`.
    @discardableResult
    public func renameSavedSearch(id: UUID, to name: String) async throws -> SavedSearch {
        let trimmed = try Validation.savedSearchName(name)
        return try await write { db in
            var search = try Self.require(SavedSearch.self, db: db, key: id)
            search.name = trimmed
            search.updatedAt = Date()
            try search.update(db)
            return search
        }
    }

    /// Replace a saved search's rules (the "re-run and re-save" edit path, 015);
    /// `.notFound` if absent; re-stamps the current version and bumps `updatedAt`.
    @discardableResult
    public func updateSavedSearchRules(id: UUID, rules: SearchRules) async throws -> SavedSearch {
        var stamped = rules
        stamped.version = SearchRules.currentVersion
        let json = try stamped.encoded()
        return try await write { db in
            var search = try Self.require(SavedSearch.self, db: db, key: id)
            search.rules = json
            search.updatedAt = Date()
            try search.update(db)
            return search
        }
    }

    /// Delete a saved search — the QUERY only. It has no FK to assets or tags
    /// (tags are referenced by id inside the rules JSON, 015), so this can never
    /// cascade a single asset away. `.notFound` if absent.
    public func deleteSavedSearch(id: UUID) async throws {
        try await write { db in
            guard try SavedSearch.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "saved_search", id: id)
            }
        }
    }

    /// Evaluate a saved search LIVE (015): decode its rules and run them through
    /// ``searchAssets``. `.notFound` if the search is absent;
    /// `.invalidSavedSearchRules` if its stored blob can't be decoded at all.
    public func evaluateSavedSearch(
        id: UUID, limit: Int = 50, after cursor: AssetPageCursor? = nil
    ) async throws -> [AssetDetail] {
        guard let search = try await savedSearch(id: id) else {
            throw AtelierError.notFound(entity: "saved_search", id: id)
        }
        guard let rules = search.decodedRules else {
            throw AtelierError.invalidSavedSearchRules(id: id)
        }
        return try await evaluate(rules: rules, limit: limit, after: cursor)
    }

    /// Evaluate an ad-hoc rule set LIVE — the same query path as a saved search,
    /// usable to PREVIEW results before saving (015). Rules referencing a DELETED
    /// tag drop that conjunct (the surviving tags still filter) rather than
    /// silently matching nothing — the "explicit over silently-empty" edge; use
    /// ``savedSearchMissingTags(id:)`` to badge which were dropped.
    public func evaluate(
        rules: SearchRules, limit: Int = 50, after cursor: AssetPageCursor? = nil
    ) async throws -> [AssetDetail] {
        let liveTagIDs = try await existingTagIDs(among: rules.tagIDs)
        return try await searchAssets(
            text: rules.text,
            platform: rules.platform,
            tagIDs: liveTagIDs,
            tagMatch: rules.tagMatch,
            // A saved search carries a SINGLE collection scope (015); the plural
            // `collectionIDs` search API takes it as a one-element list (044/045 ·
            // 16A — plural scope is a live-query affordance, not saved).
            collectionIDs: rules.collectionID.map { [$0] } ?? [],
            favoritesOnly: rules.favoritesOnly,
            colorBuckets: rules.colorBuckets,
            colorMatch: rules.colorMatch,
            // `minimumColorCoverage` is NOT a rule field: it is a tuning constant
            // like the FTS ranking weights, not part of what a saved search means.
            // Storing it would bake today's 0.15 into every blob and turn retuning
            // the floor into a data migration.
            limit: limit,
            after: cursor)
    }

    /// The tag ids a saved search references that NO LONGER exist (015 · badge
    /// "references a deleted tag"). `.notFound` if the search is absent; an
    /// undecodable rule blob yields `[]` (nothing tag-specific to report — the
    /// undecodable state is surfaced by ``evaluateSavedSearch(id:limit:after:)``
    /// throwing instead). Renaming a tag is free: rules store ids, not names, so a
    /// renamed-but-present tag never appears here.
    public func savedSearchMissingTags(id: UUID) async throws -> [UUID] {
        guard let search = try await savedSearch(id: id) else {
            throw AtelierError.notFound(entity: "saved_search", id: id)
        }
        guard let rules = search.decodedRules, !rules.tagIDs.isEmpty else { return [] }
        let present = Set(try await existingTagIDs(among: rules.tagIDs))
        return rules.tagIDs.filter { !present.contains($0) }
    }

    /// The subset of `ids` that are still real `tag` rows, order-preserving. One
    /// `IN` query, distinct-id safe. Backs both live evaluation (drop missing tag
    /// conjuncts) and the missing-tag badge.
    private func existingTagIDs(among ids: [UUID]) async throws -> [UUID] {
        guard !ids.isEmpty else { return [] }
        let present: Set<String> = try await read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let keys = ids.map(Self.key)
            let rows = try String.fetchAll(
                db, sql: "SELECT id FROM tag WHERE id IN (\(placeholders))",
                arguments: StatementArguments(keys))
            return Set(rows)
        }
        return ids.filter { present.contains(Self.key($0)) }
    }
}
