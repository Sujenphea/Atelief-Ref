// AtelierCore — the public App Services mutation surface (chunk 5, A2/A4/C6)
//
// The ONE public type of the package (A2). Every mutation in the app routes
// through this class's single private `write {}` funnel (A4): validation (C8)
// and invariants (C6) run inside or before each transaction, never bypassed,
// and GRDB errors are mapped to `AtelierError` on the way out (C7) so the
// toolkit never leaks. Reads / search are a separate chunk; this is writes only.

import Accelerate
import Foundation
import GRDB

/// The public, `Sendable` write surface over the internal ``LibraryDatabase``.
///
/// `final class … Sendable` (A3): the only stored property is the `Sendable`
/// store; no in-memory mutable state. All mutations are `async` and serialized
/// by the underlying `DatabasePool` writer (WAL).
public final class AppServices: Sendable {
    /// The internal store. Never exposed — only the funnel touches its pool.
    private let database: LibraryDatabase

    /// Open (or create) a library at `databasePath`, migrated to the latest
    /// schema.
    public init(databasePath: String) throws {
        self.database = try LibraryDatabase(path: databasePath)
    }

    /// Compose over an existing store (tests / future wiring). `internal` (A2).
    init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - The single write funnel (A4)

    /// EVERY mutation routes through here. Runs `op` in the pool's serialized
    /// writer transaction and maps any thrown error to an ``AtelierError`` (C7)
    /// so GRDB types never cross the public boundary (A2). Validation /
    /// `.notFound` thrown inside `op` pass through unchanged.
    private func write<T: Sendable>(
        _ op: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.pool.write(op)
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    /// The read counterpart of the funnel. Runs `op` in a concurrent snapshot
    /// of the pool (A3) and maps any thrown error to an ``AtelierError`` (C7) so
    /// GRDB never crosses the public boundary (A2). `.notFound` thrown inside
    /// `op` passes through unchanged. Reads do NOT serialize behind the writer —
    /// browse-while-importing (A3).
    private func read<T: Sendable>(
        _ op: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.pool.read(op)
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    // MARK: - Backup / snapshot (008 H1)

    /// Write a self-consistent, checkpointed copy of the live database to `url`
    /// via `VACUUM INTO` — one statement producing a single portable `.sqlite`
    /// with no `-wal` sidecar. `VACUUM` cannot run inside a transaction, so this
    /// takes the pool's non-transactional writer rather than the `write {}`
    /// funnel. SQLite refuses to overwrite, so `url` must not already exist.
    public func snapshot(to url: URL) async throws {
        do {
            try await database.pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
            }
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    /// `PRAGMA integrity_check` on the live database: `true` when SQLite reports
    /// the single `ok` row (healthy), `false` otherwise.
    public func integrityCheck() async throws -> Bool {
        try await read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
        }
    }

    /// Integrity-check a database FILE (a snapshot / backup) without touching the
    /// live pool — opens it read-only, runs `PRAGMA integrity_check`, closes it.
    /// Restore uses this to refuse an unhealthy snapshot before installing it;
    /// GRDB stays confined to Core (A2).
    public static func isHealthy(databaseFileAt url: URL) throws -> Bool {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
        }
    }

    // MARK: - Analysis (012 · I1)

    /// Insert or replace an asset's derived-analysis row (012 · I1).
    ///
    /// Values arrive already serialized at the AtelierIngestion analyzer seam —
    /// `colors` as opaque JSON, `phash` as the signed bit-cast of the unsigned
    /// hash — so this layer stores them verbatim (the 2A boundary; imaging types
    /// never enter Core). `analyzedAt` is stamped here (server-authoritative). The
    /// asset must exist (`.notFound`). Upsert by the `asset_id` PK, mirroring
    /// ``recordJobItem``'s explicit fetch-then-insert/update idiom, so re-analysis
    /// overwrites in place and `analysis_fts` re-indexes via its update trigger.
    @discardableResult
    public func upsertAnalysis(
        assetID: UUID,
        ocrText: String? = nil,
        colors: String? = nil,
        phash: Int64? = nil,
        analyzerVersion: Int
    ) async throws -> AssetAnalysis {
        let row = AssetAnalysis(
            assetID: assetID, ocrText: ocrText, colors: colors, phash: phash,
            analyzedAt: Date(), analyzerVersion: analyzerVersion)
        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            let exists = try AssetAnalysis
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchCount(db) > 0
            if exists { try row.update(db) } else { try row.insert(db) }
            return row
        }
    }

    /// The analysis row for `assetID`, or `nil` when the asset has not been
    /// analyzed yet.
    public func analysis(for assetID: UUID) async throws -> AssetAnalysis? {
        try await read { db in
            try AssetAnalysis
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchOne(db)
        }
    }

    /// The next batch of asset ids that need analysis at `analyzerVersion` — the
    /// resumable backfill query (012 · I1). Selects **downloaded image** assets
    /// whose analysis is either MISSING or was produced by an OLDER analyzer,
    /// newest-first, capped at `limit` (clamped to `1...1000`).
    ///
    /// Media-less kinds (they have no bytes to analyze) and video (whose analysis
    /// needs a poster-frame path, deferred) are excluded, so they never linger as
    /// perpetually-pending — the batch drains to empty and stays there until new
    /// images arrive or the analyzer version bumps. No ledger needed: "still
    /// needs analysis" is expressible as this one LEFT JOIN, so a killed backfill
    /// resumes simply by re-running it.
    public func assetsNeedingAnalysis(analyzerVersion: Int, limit: Int) async throws -> [UUID] {
        let clampedLimit = min(max(limit, 1), 1000)
        return try await read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT a.id
                FROM asset a
                LEFT JOIN asset_analysis an ON an.asset_id = a.id
                WHERE a.kind = ?
                  AND a.blob_hash IS NOT NULL
                  AND a.download_state = ?
                  AND (an.asset_id IS NULL OR an.analyzer_version < ?)
                ORDER BY a.created_at DESC
                LIMIT ?
                """, arguments: [
                    AssetKind.image.rawValue,
                    DownloadState.downloaded.rawValue,
                    analyzerVersion,
                    clampedLimit,
                ])
            return ids.compactMap { UUID(uuidString: $0) }
        }
    }

    // MARK: - Semantic embeddings (047 · Phase 3a)

    /// Insert or replace an asset's semantic text embedding (047 · 3a). `vector` is
    /// the model's `[Float]` output (already L2-normalized at the analyzer seam, so
    /// cosine reduces to a dot product); it is packed to the opaque BLOB here.
    /// `embeddedAt` is stamped server-side. Upsert by the `asset_id` PK, mirroring
    /// ``upsertAnalysis``. The asset must exist (`.notFound`).
    @discardableResult
    public func upsertEmbedding(
        assetID: UUID,
        modelVersion: Int,
        contentHash: String,
        vector: [Float]
    ) async throws -> AssetEmbedding {
        let row = AssetEmbedding(
            assetID: assetID, modelVersion: modelVersion, contentHash: contentHash,
            vector: AssetEmbedding.encode(vector), embeddedAt: Date())
        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            let exists = try AssetEmbedding
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchCount(db) > 0
            if exists { try row.update(db) } else { try row.insert(db) }
            return row
        }
    }

    /// The embedding row for `assetID`, or `nil` when not yet embedded.
    public func embedding(for assetID: UUID) async throws -> AssetEmbedding? {
        try await read { db in
            try AssetEmbedding
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchOne(db)
        }
    }

    /// The next batch of assets whose text embedding is stale at `modelVersion` —
    /// the resumable backfill query (047 · 3a). An asset qualifies when its
    /// embedding is MISSING, was produced by an OLDER model, or its OCR arrived /
    /// changed AFTER the embedding (`asset_analysis.analyzed_at > embedded_at`).
    /// Assets with no human text at all are excluded so they never linger pending.
    ///
    /// Each candidate carries its raw text fields + the existing embedding's
    /// `(modelVersion, contentHash)`, so the analyzer can build the corpus, hash
    /// it, and SKIP re-embedding when an OCR re-run left the text unchanged (the
    /// 4A content-hash guard). Name/note edits (no `asset.updated_at`) are caught
    /// by ``embeddingsToReverify(modelVersion:limit:)``.
    public func assetsNeedingEmbedding(
        modelVersion: Int, limit: Int
    ) async throws -> [EmbeddingCandidate] {
        let clampedLimit = min(max(limit, 1), 1000)
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id AS asset_id, s.title AS title, a.name AS name,
                       a.note AS note, an.ocr_text AS ocr_text,
                       e.model_version AS model_version, e.content_hash AS content_hash
                FROM asset a
                JOIN source s ON s.id = a.source_id
                LEFT JOIN asset_analysis an ON an.asset_id = a.id
                LEFT JOIN asset_embedding e ON e.asset_id = a.id
                WHERE (COALESCE(s.title,'') || COALESCE(a.name,'')
                       || COALESCE(a.note,'') || COALESCE(an.ocr_text,'')) <> ''
                  AND (e.asset_id IS NULL
                       OR e.model_version < ?
                       OR (an.analyzed_at IS NOT NULL AND an.analyzed_at > e.embedded_at))
                ORDER BY a.created_at DESC
                LIMIT ?
                """, arguments: [modelVersion, clampedLimit])
            return rows.compactMap(Self.embeddingCandidate)
        }
    }

    /// A batch of already-embedded assets to RE-VERIFY for text drift (047 · 4A),
    /// oldest-embedded first. Because `asset` carries no `updated_at`, a rename or
    /// note edit leaves no timestamp; the analyzer re-hashes each returned asset's
    /// corpus and re-embeds only on a content-hash mismatch. Paged by `embedded_at`
    /// so a periodic sweep covers the whole library over time. Only rows AT the
    /// current `modelVersion` (older ones are already caught by
    /// ``assetsNeedingEmbedding(modelVersion:limit:)``).
    public func embeddingsToReverify(
        modelVersion: Int, limit: Int
    ) async throws -> [EmbeddingCandidate] {
        let clampedLimit = min(max(limit, 1), 1000)
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id AS asset_id, s.title AS title, a.name AS name,
                       a.note AS note, an.ocr_text AS ocr_text,
                       e.model_version AS model_version, e.content_hash AS content_hash
                FROM asset_embedding e
                JOIN asset a ON a.id = e.asset_id
                JOIN source s ON s.id = a.source_id
                LEFT JOIN asset_analysis an ON an.asset_id = a.id
                WHERE e.model_version = ?
                ORDER BY e.embedded_at ASC
                LIMIT ?
                """, arguments: [modelVersion, clampedLimit])
            return rows.compactMap(Self.embeddingCandidate)
        }
    }

    /// Bump an embedding's `embedded_at` to now WITHOUT re-embedding — a re-verify
    /// (047 · 4A) that found the text unchanged. Rotates the row out of the
    /// oldest-first re-verify window so the sweep advances. No-op if absent.
    public func markEmbeddingVerified(assetID: UUID) async throws {
        try await write { db in
            try db.execute(sql: """
                UPDATE asset_embedding SET embedded_at = ? WHERE asset_id = ?
                """, arguments: [Date(), Self.key(assetID)])
        }
    }

    /// Semantic (meaning-based) search over the library (047 · 3a). Ranks assets
    /// by cosine similarity between `queryVector` and each asset's stored text
    /// embedding, respecting the same structured scope as keyword search.
    ///
    /// - `queryVector`: the search text ALREADY embedded into the model's space by
    ///   the caller (the embedder lives in AtelierIngestion; AtelierCore can't turn
    ///   a string into a vector). Empty → empty result (no match-everything).
    /// - `modelVersion`: only embeddings at this version are comparable to the
    ///   query (a mixed-version library is mid-backfill); others are ignored.
    /// - `platform` / `tagIDs` / `tagMatch` / `collectionIDs`: structured filters,
    ///   applied in SQL FIRST (8A) so cosine ranks only in-scope candidates — a
    ///   nearer match outside the scope never displaces a real one.
    ///
    /// Ranking is Swift-side brute-force cosine (SQLite has no vector index): load
    /// the in-scope `(id, vector)` pairs, dot-product each against the query
    /// (vectors are L2-normalized, so dot == cosine), take the top `limit`. This is
    /// bounded for library-scale collections (≤ tens of thousands); a vector index
    /// / ANN is the escape hatch if profiling ever demands it. NOT keyset-pageable
    /// (relevance order isn't the recency cursor's order) — `limit` only.
    public func semanticSearchAssets(
        queryVector: [Float],
        modelVersion: Int,
        platform: Platform? = nil,
        tagIDs: [UUID] = [],
        tagMatch: TagMatch = .all,
        collectionIDs: [UUID] = [],
        limit: Int = 50
    ) async throws -> [AssetDetail] {
        guard !queryVector.isEmpty else { return [] }
        let clampedLimit = min(max(limit, 1), 500)
        let distinctTagIDs = Array(Set(tagIDs))
        let distinctCollectionIDs = Array(Set(collectionIDs))

        return try await read { db in
            // 1. In-scope candidates (8A). These structured predicates mirror the
            //    same filters in `searchAssets` (platform / collection membership /
            //    tag set semantics) — kept as focused SQL here rather than sharing
            //    the FTS query builder, since this path has no text arms.
            var sql = """
                SELECT e.asset_id AS asset_id, e.vector AS vector
                FROM asset_embedding e
                JOIN asset a ON a.id = e.asset_id
                """
            var conditions = ["e.model_version = ?"]
            var args: [DatabaseValueConvertible] = [modelVersion]
            if let platform {
                sql += "\n                JOIN source s ON s.id = a.source_id"
                conditions.append("s.platform = ?")
                args.append(platform.rawValue)
            }
            if !distinctCollectionIDs.isEmpty {
                let placeholders = databaseQuestionMarks(count: distinctCollectionIDs.count)
                conditions.append(
                    "a.id IN (SELECT asset_id FROM collection_item WHERE collection_id IN (\(placeholders)))")
                args.append(contentsOf: distinctCollectionIDs.map(Self.key))
            }
            if !distinctTagIDs.isEmpty {
                let placeholders = databaseQuestionMarks(count: distinctTagIDs.count)
                switch tagMatch {
                case .any:
                    conditions.append(
                        "a.id IN (SELECT asset_id FROM asset_tag WHERE tag_id IN (\(placeholders)))")
                    args.append(contentsOf: distinctTagIDs.map(Self.key))
                case .all:
                    conditions.append("""
                        a.id IN (SELECT asset_id FROM asset_tag WHERE tag_id IN (\(placeholders)) \
                        GROUP BY asset_id HAVING COUNT(DISTINCT tag_id) = ?)
                        """)
                    args.append(contentsOf: distinctTagIDs.map(Self.key))
                    args.append(distinctTagIDs.count)
                }
            }
            sql += "\n                WHERE " + conditions.joined(separator: " AND ")

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            // 2. Cosine = dot product (both sides L2-normalized). Query normalization
            //    only scales all scores by |query|, which doesn't change the ranking,
            //    so a non-unit query still orders correctly. Skip any dimension
            //    mismatch defensively (a stale-shape vector never crashes the sort).
            let dims = queryVector.count
            var scored: [(id: UUID, score: Float)] = []
            scored.reserveCapacity(rows.count)
            for row in rows {
                guard let idString: String = row["asset_id"],
                      let id = UUID(uuidString: idString),
                      let data: Data = row["vector"] else { continue }
                let vector = AssetEmbedding.vectorFloats(data)
                guard vector.count == dims else { continue }
                var score: Float = 0
                vDSP_dotpr(queryVector, 1, vector, 1, &score, vDSP_Length(dims))
                scored.append((id, score))
            }
            // Nearest first; ascending-id tiebreak so equal scores are deterministic.
            scored.sort {
                $0.score != $1.score ? $0.score > $1.score
                    : $0.id.uuidString < $1.id.uuidString
            }
            let topIDs = scored.prefix(clampedLimit).map(\.id)
            guard !topIDs.isEmpty else { return [] }

            // 3. Hydrate details and restore the ranked order (the IN fetch is
            //    unordered; the dictionary reorders by rank).
            let keys = topIDs.map(Self.key)
            let request = Asset
                .filter(keys.contains(Column("id")))
                .including(required: Asset.source)
            let details = try AssetSourceRow.fetchAll(db, request)
                .map { AssetDetail(asset: $0.asset, source: $0.source) }
            let byID = Dictionary(uniqueKeysWithValues: details.map { ($0.asset.id, $0) })
            return topIDs.compactMap { byID[$0] }
        }
    }

    /// Decode a candidate row (shared by the two backfill queries).
    private static func embeddingCandidate(_ row: Row) -> EmbeddingCandidate? {
        guard let idString: String = row["asset_id"], let id = UUID(uuidString: idString) else {
            return nil
        }
        return EmbeddingCandidate(
            assetID: id,
            title: row["title"], name: row["name"], note: row["note"],
            ocrText: row["ocr_text"],
            existingModelVersion: row["model_version"],
            existingContentHash: row["content_hash"])
    }

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
            guard var search = try SavedSearch.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "saved_search", id: id)
            }
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
            guard var search = try SavedSearch.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "saved_search", id: id)
            }
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

    // MARK: - Collections

    /// Create a collection (a folder — folders ARE collections, decision F1).
    /// Validates + trims the name (C8); the service generates `id` and
    /// `createdAt`/`updatedAt` (server-authoritative). When `parent` is given it
    /// must exist (`.notFound`) — the new collection nests under it; `nil` ⇒ a
    /// root folder (the existing no-parent behaviour).
    @discardableResult
    public func createCollection(
        name: String, description: String? = nil, parent parentID: UUID? = nil
    ) async throws -> Collection {
        let trimmed = try Validation.collectionName(name)
        let now = Date()
        return try await write { db in
            if let parentID {
                guard try Collection.exists(db, key: Self.key(parentID)) else {
                    throw AtelierError.notFound(entity: "collection", id: parentID)
                }
            }
            // Auto-disambiguate a duplicate sibling name, Finder-style (043 · 2c).
            let unique = Validation.uniqueCollectionName(
                trimmed, among: try Self.siblingNames(parentID, in: db))
            // Append: the new folder lands after its existing siblings, keeping
            // the group dense at `0..<n` (043 · 2B).
            var toInsert = Collection(
                id: UUID(), name: unique, description: description,
                coverAssetID: nil, createdAt: now, updatedAt: now,
                parentCollectionID: parentID)
            toInsert.sortIndex = try Self.childIDsOrdered(parentID, in: db).count
            try toInsert.insert(db)
            return toInsert
        }
    }

    /// Rename a collection. Rejects the protected Unsorted folder
    /// (`.protectedCollection`, F3); `.notFound` if absent; bumps `updatedAt`.
    @discardableResult
    public func renameCollection(id: UUID, to name: String) async throws -> Collection {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        let trimmed = try Validation.collectionName(name)
        return try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            // Auto-disambiguate against the OTHER siblings (exclude self, so a
            // no-op rename to the current name doesn't drift — 043 · 2c).
            collection.name = Validation.uniqueCollectionName(
                trimmed,
                among: try Self.siblingNames(
                    collection.parentCollectionID, excluding: id, in: db))
            collection.updatedAt = Date()
            try collection.update(db)
            return collection
        }
    }

    /// Set a collection's cover. Both the collection and the asset must exist
    /// (`.notFound`); bumps `updatedAt`.
    public func setCollectionCover(collectionID: UUID, assetID: UUID) async throws {
        try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            collection.coverAssetID = assetID
            collection.updatedAt = Date()
            try collection.update(db)
        }
    }

    /// Delete a collection (folder). Rejects the protected Unsorted folder
    /// (`.protectedCollection`, F3); `.notFound` if absent. The whole subtree —
    /// descendant folders (parent FK) and every membership (schema 17A) —
    /// CASCADEs at the DB level (F4); descendants are NOT hand-deleted here.
    public func deleteCollection(id: UUID) async throws {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        try await write { db in
            guard let doomed = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            let formerParentID = doomed.parentCollectionID
            _ = try Collection.deleteOne(db, key: Self.key(id))
            // The cascade drops this folder's whole subtree; only the FORMER
            // parent's remaining children need renumbering to stay dense (043 · 2B).
            let remaining = try Self.childIDsOrdered(formerParentID, in: db)
            try Self.applyDenseOrder(remaining, in: db)
        }
    }

    /// Reparent AND/OR reposition a folder (decision F6 · 043 · 2B). Rejects the
    /// protected Unsorted folder (`.protectedCollection`, F3); the folder must
    /// exist (`.notFound`). When `newParentID` is non-nil it must exist
    /// (`.notFound`) and must NOT be `id` nor a descendant of `id` — else
    /// `.folderCycle`. `nil` ⇒ the folder becomes a root.
    ///
    /// `index` is the destination position among the destination group's children
    /// **with the moved folder removed** (`0` = first, `nil` = append last); it is
    /// clamped to a valid range. Both the destination group and — when the parent
    /// changed — the former group are renumbered to a dense `0..<n`. Bumps
    /// `updatedAt` (a user-visible change). This single op backs the "Move to ▸"
    /// menu (append via `index: nil`), a same-parent drag reorder (same parent,
    /// explicit `index`), and a reparent-with-position drag.
    public func moveCollection(
        id: UUID, toParent newParentID: UUID?, index: Int? = nil
    ) async throws {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            let oldParentID = collection.parentCollectionID
            if let newParentID {
                guard try Collection.exists(db, key: Self.key(newParentID)) else {
                    throw AtelierError.notFound(entity: "collection", id: newParentID)
                }
                // Cycle prevention (F6): walk UP the ancestor chain from the
                // proposed parent via parent_collection_id. If the walk reaches
                // `id`, then `id` is an ancestor of newParentID — i.e.
                // newParentID is `id` itself or one of its descendants — so the
                // move would form a cycle. A self-move (newParentID == id) is
                // caught on the very first step.
                var cursor: UUID? = newParentID
                while let current = cursor {
                    if current == id {
                        throw AtelierError.folderCycle
                    }
                    cursor = try Collection
                        .filter(Column("id") == Self.key(current))
                        .select(Column("parent_collection_id"), as: UUID?.self)
                        .fetchOne(db) ?? nil
                }
            }
            collection.parentCollectionID = newParentID
            collection.updatedAt = Date()
            try collection.update(db)
            // Insert `id` at `index` among the destination group and renumber it
            // dense. The moved row still carries its stale old index, so strip +
            // reinsert rather than trust its position.
            var siblings = try Self.childIDsOrdered(newParentID, in: db)
            siblings.removeAll { $0 == id }
            let target = min(max(index ?? siblings.count, 0), siblings.count)
            siblings.insert(id, at: target)
            try Self.applyDenseOrder(siblings, in: db)
            // A parent change leaves a gap in the former group — close it too.
            if oldParentID != newParentID {
                let formerSiblings = try Self.childIDsOrdered(oldParentID, in: db)
                try Self.applyDenseOrder(formerSiblings, in: db)
            }
        }
    }

    /// The DIRECT children of a folder (decision F5/P13), in manual order —
    /// persisted `sort_index`, tie-broken by `(name, id)` (043 · 2B). `nil` ⇒ the
    /// root folders (`parent_collection_id IS NULL`, including the protected
    /// Unsorted folder). Read.
    public func childCollections(of parentID: UUID?) async throws -> [Collection] {
        try await read { db in
            let filter: QueryInterfaceRequest<Collection>
            if let parentID {
                filter = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
            } else {
                filter = Collection.filter(Column("parent_collection_id") == nil)
            }
            return try filter
                .order(Column("sort_index"), Column("name"), Column("id"))
                .fetchAll(db)
        }
    }

    /// A parent's child ids in canonical order — persisted `sort_index`,
    /// tie-broken by `(name, id)`. `nil` parent = the roots. The single seam used
    /// to renumber a sibling group after a create / delete / move (043 · 2B).
    private static func childIDsOrdered(_ parentID: UUID?, in db: Database) throws -> [UUID] {
        let base: QueryInterfaceRequest<Collection>
        if let parentID {
            base = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
        } else {
            base = Collection.filter(Column("parent_collection_id") == nil)
        }
        return try base
            .order(Column("sort_index"), Column("name"), Column("id"))
            .fetchAll(db).map(\.id)
    }

    /// The names of the folders under `parentID` (`nil` = roots), optionally
    /// EXCLUDING one id (the folder being renamed, so it doesn't collide with its
    /// own name). Feeds `Validation.uniqueCollectionName` (043 · policy 2c).
    private static func siblingNames(
        _ parentID: UUID?, excluding excludedID: UUID? = nil, in db: Database
    ) throws -> [String] {
        let base: QueryInterfaceRequest<Collection>
        if let parentID {
            base = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
        } else {
            base = Collection.filter(Column("parent_collection_id") == nil)
        }
        let query = excludedID.map { base.filter(Column("id") != Self.key($0)) } ?? base
        return try query.fetchAll(db).map(\.name)
    }

    /// Write a dense `0..<n` `sort_index` for `orderedIDs`, in order. A targeted
    /// column UPDATE (not a record `update`) so it does NOT bump `updated_at` — a
    /// renumber is structural bookkeeping, not a user edit.
    private static func applyDenseOrder(_ orderedIDs: [UUID], in db: Database) throws {
        for (position, id) in orderedIDs.enumerated() {
            try db.execute(
                sql: "UPDATE collection SET sort_index = ? WHERE id = ?",
                arguments: [position, Self.key(id)])
        }
    }

    /// The fixed id of the protected default-import "Unsorted" folder (F3), so
    /// the app has a default target without reaching into the domain constant.
    public var unsortedFolderID: UUID { Collection.unsortedID }

    // MARK: - Ingest (C6 provenance + 18A dedup)

    /// Ingest an asset with its REQUIRED provenance into a collection, in ONE
    /// transaction (C6 — `source` is non-optional, so "asset with no origin"
    /// cannot compile). Implements the 18A dedup rule and is idempotent on
    /// re-ingest of identical bytes + provenance into the same collection.
    ///
    /// Steps inside the funnel:
    /// 1. validate dimensions / fileSize / blobHash / per-platform originalURL
    ///    (+ placement if supplied);
    /// 2. assert the target collection exists (`.notFound`);
    /// 3. **18A dedup** — reuse an existing asset (and its source) sharing the
    ///    blob hash whose source matches the incoming provenance;
    /// 4. ensure exactly ONE membership of the resolved asset in the collection.
    @discardableResult
    public func ingest(
        _ asset: AssetDraft,
        from source: SourceDraft,
        into collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) async throws -> IngestResult {
        // 1. validate (fail fast, before opening the write).
        try Validation.dimensions(width: asset.width, height: asset.height)
        try Validation.fileSize(asset.fileSize)
        let blobHash = try Validation.blobHash(asset.blobHash)
        try Validation.originalURL(source.originalURL, platform: source.platform)
        if let placement {
            try Validation.canvasPlacement(
                x: placement.x, y: placement.y, w: placement.w, h: placement.h)
        }

        return try await write { db in
            // 2. the collection must exist.
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }

            // 3. 18A dedup — reuse an existing asset+source on match.
            let resolvedAsset: Asset
            let wasDeduplicated: Bool
            if let existing = try Self.findDuplicate(db, blobHash: blobHash, source: source) {
                resolvedAsset = existing
                wasDeduplicated = true
            } else {
                let newSource = Source(
                    id: UUID(), platform: source.platform,
                    originalURL: source.originalURL, authorHandle: source.authorHandle,
                    authorName: source.authorName, title: source.title,
                    capturedAt: source.capturedAt, rawMetadata: source.rawMetadata)
                try newSource.insert(db)
                let newAsset = Asset(
                    id: UUID(), kind: asset.kind, blobHash: blobHash,
                    mimeType: asset.mimeType, width: asset.width, height: asset.height,
                    duration: asset.duration, fileSize: asset.fileSize,
                    downloadState: asset.downloadState, createdAt: Date(),
                    sourceId: newSource.id)
                try newAsset.insert(db)
                resolvedAsset = newAsset
                wasDeduplicated = false
            }

            // 4. ensure ONE membership (ingest is idempotent on membership; a
            //    second placement of the same asset is a deliberate caller act
            //    via addAssets, not a side effect of re-ingest).
            let alreadyMember = try Self.membership(
                db, collectionID: collectionID, assetID: resolvedAsset.id) != nil
            if !alreadyMember {
                let item = CollectionItem(
                    id: UUID(), collectionID: collectionID, assetID: resolvedAsset.id,
                    addedAt: Date(),
                    manualOrder: try Self.nextManualOrder(db, collectionID: collectionID),
                    canvasX: placement?.x, canvasY: placement?.y,
                    canvasW: placement?.w, canvasH: placement?.h, canvasZ: placement?.z)
                try item.insert(db)
            }

            return IngestResult(asset: resolvedAsset, wasDeduplicated: wasDeduplicated)
        }
    }

    /// Ingest a MEDIA-LESS asset (003 · O1) — a `color` / `link` / `tweet` — with
    /// its REQUIRED provenance into a collection, in ONE transaction (C6). The
    /// sibling of ``ingest(_:from:into:placement:)`` for the content path: the
    /// asset's substance is its ``AssetPayload`` and it is born `.downloaded`.
    /// Kind-aware dedup reuses an existing asset+source sharing the same
    /// `(kind, dedup_key)` and provenance.
    ///
    /// `blob` (003 · C3, Option 3) is the OPTIONAL card image: when present the
    /// otherwise media-less asset ALSO stores a real blob (its `blob_hash` / mime
    /// / dims / size), so a tweet renders its picture rather than a text card. The
    /// bytes never affect identity — dedup stays keyed on `(kind, dedup_key)` — so
    /// two captures with different card images resolve to one tweet (first capture
    /// wins; a later card image does NOT overwrite an existing asset's blob).
    ///
    /// Steps inside the funnel:
    /// 1. normalize + validate the draft (per-kind payload, canonical dedup key),
    ///    the optional blob facts (dims / size / hash), and the per-platform
    ///    `originalURL` (+ placement if supplied);
    /// 2. assert the target collection exists (`.notFound`);
    /// 3. **kind-aware dedup** — reuse an asset with the same `(kind, dedup_key)`
    ///    whose source matches the incoming provenance;
    /// 4. ensure exactly ONE membership of the resolved asset in the collection.
    @discardableResult
    public func ingestContent(
        _ draft: AssetContentDraft,
        blob: ContentBlobFacts? = nil,
        from source: SourceDraft,
        into collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) async throws -> IngestResult {
        // 1. validate + normalize (fail fast, before opening the write).
        let normalized = try Validation.contentDraft(draft)
        // Validate the optional card-image blob facts (Option 3). Held as a plain
        // tuple so the @Sendable write closure can capture it; the hash is
        // canonicalized (lowercased-hex) exactly like the byte path.
        let normalizedBlob: (hash: String, mimeType: String, width: Int, height: Int, fileSize: Int)?
        if let blob {
            try Validation.dimensions(width: blob.width, height: blob.height)
            try Validation.fileSize(blob.fileSize)
            normalizedBlob = (
                try Validation.blobHash(blob.blobHash), blob.mimeType,
                blob.width, blob.height, blob.fileSize)
        } else {
            normalizedBlob = nil
        }
        // Align the source's `original_url` with the kind's canonical identity so
        // two captures of the same thing dedup even when written differently: a
        // link's `original_url` becomes its canonical URL (003 · C2); a tweet's
        // becomes the deterministic permalink for its id, so `x.com` /
        // `twitter.com` / tracking-param variants share one source (003 · C3).
        // A `let` so the @Sendable write closure can capture it.
        let effectiveSource: SourceDraft = {
            guard let canonical = normalized.dedupKey else { return source }
            var s = source
            switch normalized.kind {
            case .link:
                s.originalURL = canonical
            case .tweet:
                s.originalURL = TweetPayload.canonicalTweetURL(id: canonical)
            default:
                return source
            }
            return s
        }()
        try Validation.originalURL(effectiveSource.originalURL, platform: effectiveSource.platform)
        if let placement {
            try Validation.canvasPlacement(
                x: placement.x, y: placement.y, w: placement.w, h: placement.h)
        }

        return try await write { db in
            // 2. the collection must exist.
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }

            // 3. kind-aware dedup — reuse an existing content asset+source on match.
            let resolvedAsset: Asset
            let wasDeduplicated: Bool
            if let existing = try Self.findDuplicateContent(
                db, kind: normalized.kind, dedupKey: normalized.dedupKey, source: effectiveSource) {
                resolvedAsset = existing
                wasDeduplicated = true
            } else {
                let newSource = Source(
                    id: UUID(), platform: effectiveSource.platform,
                    originalURL: effectiveSource.originalURL, authorHandle: effectiveSource.authorHandle,
                    authorName: effectiveSource.authorName, title: effectiveSource.title,
                    capturedAt: effectiveSource.capturedAt, rawMetadata: effectiveSource.rawMetadata)
                try newSource.insert(db)
                // Content in `payload`; born `.downloaded` (its substance is fully
                // present). Byte columns are nil UNLESS a card image was supplied
                // (Option 3) — then the asset also carries a real blob.
                let newAsset = Asset(
                    id: UUID(), kind: normalized.kind,
                    blobHash: normalizedBlob?.hash, mimeType: normalizedBlob?.mimeType,
                    width: normalizedBlob?.width, height: normalizedBlob?.height,
                    duration: nil, fileSize: normalizedBlob?.fileSize,
                    downloadState: .downloaded,
                    createdAt: Date(), sourceId: newSource.id,
                    payload: normalized.payload.jsonString(),
                    dedupKey: normalized.dedupKey, searchText: normalized.searchText)
                try newAsset.insert(db)
                resolvedAsset = newAsset
                wasDeduplicated = false
            }

            // 4. ensure ONE membership (idempotent on membership — matches ingest).
            let alreadyMember = try Self.membership(
                db, collectionID: collectionID, assetID: resolvedAsset.id) != nil
            if !alreadyMember {
                let item = CollectionItem(
                    id: UUID(), collectionID: collectionID, assetID: resolvedAsset.id,
                    addedAt: Date(),
                    manualOrder: try Self.nextManualOrder(db, collectionID: collectionID),
                    canvasX: placement?.x, canvasY: placement?.y,
                    canvasW: placement?.w, canvasH: placement?.h, canvasZ: placement?.z)
                try item.insert(db)
            }

            return IngestResult(asset: resolvedAsset, wasDeduplicated: wasDeduplicated)
        }
    }

    // MARK: - Arrange / bulk (P15 — each ONE transaction)

    /// Set (or clear) the canvas placement of an asset's membership. Validates
    /// finite/positive (C8); `.notFound` if the asset is not a member.
    public func setCanvasPlacement(
        collectionID: UUID, assetID: UUID,
        x: Double?, y: Double?, w: Double?, h: Double?, z: Int?
    ) async throws {
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        try await write { db in
            guard var item = try Self.membership(
                db, collectionID: collectionID, assetID: assetID) else {
                throw AtelierError.notFound(entity: "collection_item", id: assetID)
            }
            item.canvasX = x
            item.canvasY = y
            item.canvasW = w
            item.canvasH = h
            item.canvasZ = z
            try item.update(db)
        }
    }

    /// The next append slot for a collection's manual order: one past the current
    /// max, or 0 when the collection has no ordered items yet. Assigned to a new
    /// membership at insert so a fresh import/add lands at the END of the manual
    /// grid, in insertion order — instead of at a random position (a NULL
    /// `manual_order` sorts first and ties break on the membership's random UUID).
    /// SQLite makes uncommitted inserts visible within the same transaction, so a
    /// batch that calls this per item still increments correctly.
    static func nextManualOrder(_ db: Database, collectionID: UUID) throws -> Int {
        let maxOrder = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(manual_order), -1) FROM collection_item
                WHERE collection_id = ?
                """,
            arguments: [Self.key(collectionID)]) ?? -1
        return maxOrder + 1
    }

    /// Assign `manualOrder` 0,1,2,… to the listed memberships, IN ONE
    /// transaction (P15). `.notFound` (rolling back the whole batch) if a listed
    /// asset is not a member.
    public func setGridOrder(collectionID: UUID, orderedAssetIDs: [UUID]) async throws {
        try await write { db in
            for (index, assetID) in orderedAssetIDs.enumerated() {
                guard var item = try Self.membership(
                    db, collectionID: collectionID, assetID: assetID) else {
                    throw AtelierError.notFound(entity: "collection_item", id: assetID)
                }
                item.manualOrder = index
                try item.update(db)
            }
        }
    }

    /// Set a collection's grid sort mode (007). Persists `collection.sort_mode`
    /// and bumps `updatedAt`, IN ONE write. `.notFound` if absent. Non-destructive
    /// — `manual_order` is untouched, so switching to and from `.manual` restores
    /// the drag arrangement.
    public func setCollectionSortMode(_ mode: SortMode, for collectionID: UUID) async throws {
        try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            collection.sortMode = mode
            collection.updatedAt = Date()
            try collection.update(db)
        }
    }

    /// Record a view of each listed asset (007 · a view = an Item Detail open),
    /// IN ONE transaction (P15). Each DISTINCT id's `view_count` is incremented
    /// by one and `last_viewed_at` set to `at` — so N opens coalesced by the
    /// caller land as one bump per asset. Unknown ids are silently skipped
    /// (idempotent; a since-deleted asset is a harmless no-op). Duplicate ids in
    /// the batch count once. Negligible against the WAL.
    public func recordViews(_ assetIDs: [UUID], at date: Date = Date()) async throws {
        let distinct = Array(Set(assetIDs))
        guard !distinct.isEmpty else { return }
        try await write { db in
            for id in distinct {
                try db.execute(sql: """
                    UPDATE asset SET view_count = view_count + 1, last_viewed_at = ?
                    WHERE id = ?
                    """, arguments: [date, Self.key(id)])
            }
        }
    }

    /// Bulk-add memberships, IN ONE transaction (P15). Idempotent per asset
    /// (skips ones already members). `.notFound` (rolling back) for a missing
    /// collection or asset.
    public func addAssets(_ assetIDs: [UUID], to collectionID: UUID) async throws {
        try await write { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            let now = Date()
            // Append the batch after any existing items, in the given order — each
            // newly-inserted membership takes the next manual slot (skipped assets
            // that are already members don't consume one).
            var order = try Self.nextManualOrder(db, collectionID: collectionID)
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                let isMember = try Self.membership(
                    db, collectionID: collectionID, assetID: assetID) != nil
                if !isMember {
                    let item = CollectionItem(
                        id: UUID(), collectionID: collectionID,
                        assetID: assetID, addedAt: now, manualOrder: order)
                    try item.insert(db)
                    order += 1
                }
            }
        }
    }

    /// Bulk-remove memberships, IN ONE transaction (P15). Idempotent — removing
    /// a non-member is a no-op.
    public func removeAssets(_ assetIDs: [UUID], from collectionID: UUID) async throws {
        try await write { db in
            for assetID in assetIDs {
                try CollectionItem
                    .filter(Column("collection_id") == Self.key(collectionID))
                    .filter(Column("asset_id") == Self.key(assetID))
                    .deleteAll(db)
            }
        }
    }

    /// Atomically MOVE memberships between collections (009 · N1), IN ONE
    /// transaction — the domain's triage verb, so a crash can never leave an
    /// asset vanished from both collections or silently duplicated half-moved.
    /// Per asset: gain a membership in `targetID` (skipped when already a
    /// member — the dedup mirrors `addAssets`, so an already-member asset
    /// simply loses its source membership), then lose the `sourceID`
    /// membership (idempotent — a stale payload whose asset was already
    /// removed from the source still honors the "put it there" intent, 9A).
    /// `.notFound` (rolling back the whole batch) for a missing source/target
    /// collection or asset. `sourceID == targetID` and an empty batch are
    /// no-ops. Duplicate ids in one batch land a single membership.
    ///
    /// New target memberships are explicitly APPENDED to the manual order
    /// (`max(manual_order) + 1, +2, …` in batch order) so a move lands at the
    /// target's feed end deterministically (17A). Fresh `addAssets`
    /// memberships stay NULL — which `.manual`'s `ORDER BY manual_order`
    /// sorts FIRST — so without the append a move into an arranged collection
    /// would surface at the front, breaking the "it went to the end" promise
    /// move makes (copy/import keep their existing placement semantics).
    public func moveAssets(_ assetIDs: [UUID], from sourceID: UUID, to targetID: UUID) async throws {
        guard sourceID != targetID, !assetIDs.isEmpty else { return }
        try await write { db in
            guard try Collection.exists(db, key: Self.key(sourceID)) else {
                throw AtelierError.notFound(entity: "collection", id: sourceID)
            }
            guard try Collection.exists(db, key: Self.key(targetID)) else {
                throw AtelierError.notFound(entity: "collection", id: targetID)
            }
            let now = Date()
            var nextOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(manual_order), -1) + 1 FROM collection_item
                WHERE collection_id = ?
                """, arguments: [Self.key(targetID)]) ?? 0
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                let isMember = try Self.membership(
                    db, collectionID: targetID, assetID: assetID) != nil
                if !isMember {
                    let item = CollectionItem(
                        id: UUID(), collectionID: targetID,
                        assetID: assetID, addedAt: now, manualOrder: nextOrder)
                    try item.insert(db)
                    nextOrder += 1
                }
                try CollectionItem
                    .filter(Column("collection_id") == Self.key(sourceID))
                    .filter(Column("asset_id") == Self.key(assetID))
                    .deleteAll(db)
            }
        }
    }

    /// Delete assets ENTIRELY from the library (not just one folder membership),
    /// IN ONE transaction. Idempotent — an unknown / already-deleted id is
    /// skipped, not an error (so concurrent or repeated deletes are safe).
    ///
    /// For each existing target the `asset` row is removed, which CASCADEs its
    /// memberships (17A) and tag links, and clears any folder cover
    /// (`cover_asset_id` → NULL) at the DB level. Then two GC passes run in the
    /// same transaction:
    /// - **Sources** — a `source` is kept by `asset.source_id`'s `ON DELETE
    ///   RESTRICT`, so we delete each touched source whose last asset is now
    ///   gone (an orphaned source would otherwise linger and defeat 18A dedup).
    /// - **Blobs** — a blob hash is reported reclaimable ONLY when no remaining
    ///   asset shares it (dedup-safe: content-identical assets keep the file).
    ///
    /// Returns the reclaimable blobs as ``OrphanedBlob`` so the caller (which
    /// owns the `MediaStore`) can trash the on-disk blob + thumbnail files; Core
    /// itself never touches the filesystem. Tag rows survive (only the
    /// `asset_tag` join cascades), matching ``removeTag(_:from:source:)``.
    @discardableResult
    public func deleteAssets(_ assetIDs: [UUID]) async throws -> [OrphanedBlob] {
        try await write { db in try Self.performDelete(assetIDs, in: db) }
    }

    /// The delete cascade, shared by ``deleteAssets(_:)`` and the recoverable
    /// variant so both run the SAME transaction logic (010 · delete-undo).
    private static func performDelete(_ assetIDs: [UUID], in db: Database) throws -> [OrphanedBlob] {
        // Resolve the targets that actually exist and remove them. Track a
        // representative mime per distinct hash (for extension round-trip)
        // and the set of sources touched, both in stable first-seen order.
        var mimeByHash: [String: String] = [:]
        var orderedHashes: [String] = []
        var orderedSourceKeys: [String] = []
        var seenSourceKeys: Set<String> = []
        for assetID in assetIDs {
            guard let asset = try Asset.fetchOne(db, key: Self.key(assetID)) else {
                continue // idempotent: unknown / already-deleted id.
            }
            // A media-less asset (003 · O1) has no blob to reclaim — only
            // byte-backed assets contribute an orphan-candidate hash.
            if let hash = asset.blobHash, mimeByHash[hash] == nil {
                mimeByHash[hash] = asset.mimeType ?? ""
                orderedHashes.append(hash)
            }
            let sourceKey = Self.key(asset.sourceId)
            if seenSourceKeys.insert(sourceKey).inserted {
                orderedSourceKeys.append(sourceKey)
            }
            try asset.delete(db)
        }

        // GC sources whose last asset is gone (RESTRICT keeps them otherwise).
        for sourceKey in orderedSourceKeys {
            let stillReferenced = try Asset
                .filter(Column("source_id") == sourceKey)
                .fetchCount(db) > 0
            if !stillReferenced {
                try Source.deleteOne(db, key: sourceKey)
            }
        }

        // A blob is reclaimable only when no remaining asset shares its hash.
        var orphans: [OrphanedBlob] = []
        for hash in orderedHashes {
            let stillReferenced = try Asset
                .filter(Column("blob_hash") == hash)
                .fetchCount(db) > 0
            if !stillReferenced {
                orphans.append(OrphanedBlob(blobHash: hash, mimeType: mimeByHash[hash]!))
            }
        }
        // "Delete is forgotten": the orphaned bytes are leaving the store, so drop
        // the bulk-import ledger rows that marked this content known — a future
        // sweep then re-ingests it. Keyed on blob ORPHANING (not per-asset): while
        // any asset still shares the blob, the content is present and legitimately
        // known.
        try Self.forgetOrphanedKnownItems(orphans.map(\.blobHash), in: db)
        return orphans
    }

    // MARK: - Delete-undo (010)

    /// Delete assets AND capture a verbatim backup for undo, in ONE transaction
    /// (010 · delete-undo). The backup is the exact graph removed — assets, their
    /// sources, memberships (with order), tag links, and the covers the delete
    /// `SET NULL`-ed — captured with set-based `IN (…)` reads (no N+1) BEFORE the
    /// shared cascade runs, so it can't drift from what was deleted.
    ///
    /// Blobs are NOT reaped here (unlike the model's old delete path): reaping is
    /// deferred to the launch orphan-GC, so ``restoreDeletedAssets(_:)`` finds the
    /// bytes still on disk. A delete that is never undone is reclaimed next launch.
    public func deleteAssetsRecoverable(_ assetIDs: [UUID]) async throws -> DeletedAssetsBackup {
        try await write { db in
            let backup = try Self.captureBackup(assetIDs, in: db)
            _ = try Self.performDelete(assetIDs, in: db)
            return backup
        }
    }

    /// Snapshot the full graph the delete will remove (set-based reads).
    private static func captureBackup(_ assetIDs: [UUID], in db: Database) throws -> DeletedAssetsBackup {
        let keys = assetIDs.map(Self.key)
        guard !keys.isEmpty else { return DeletedAssetsBackup() }

        let assets = try Asset.filter(keys.contains(Column("id"))).fetchAll(db)
        guard !assets.isEmpty else { return DeletedAssetsBackup() }

        let sourceKeys = Array(Set(assets.map { Self.key($0.sourceId) }))
        let sources = try Source.filter(sourceKeys.contains(Column("id"))).fetchAll(db)
        let memberships = try CollectionItem.filter(keys.contains(Column("asset_id"))).fetchAll(db)
        let tagLinks = try AssetTag.filter(keys.contains(Column("asset_id"))).fetchAll(db)

        let coverRows = try Row.fetchAll(db, sql: """
            SELECT id AS cid, cover_asset_id AS aid FROM collection
            WHERE cover_asset_id IN (\(databaseQuestionMarks(count: keys.count)))
            """, arguments: StatementArguments(keys))
        let covers = coverRows.compactMap { row -> DeletedAssetsBackup.CoverRef? in
            guard let cid = UUID(uuidString: row["cid"]),
                  let aid = UUID(uuidString: row["aid"]) else { return nil }
            return DeletedAssetsBackup.CoverRef(collectionID: cid, assetID: aid)
        }
        return DeletedAssetsBackup(
            assets: assets, sources: sources, memberships: memberships,
            tagLinks: tagLinks, covers: covers)
    }

    /// Reinstate a ``DeletedAssetsBackup`` verbatim — the inverse of
    /// ``deleteAssetsRecoverable(_:)``. ONE transaction, best-effort per row (010 ·
    /// 4A): idempotent (skip-if-exists), dedup-aware (an asset whose dedup key a
    /// live capture recreated is skipped, not duplicated), and resilient (a
    /// membership whose collection was since deleted is skipped; a cover is
    /// restored only if the collection is still cover-less). Ids / timestamps /
    /// manual order are preserved. Blobs are untouched (never reaped), so restored
    /// byte-backed assets keep their media.
    public func restoreDeletedAssets(_ backup: DeletedAssetsBackup) async throws {
        guard !backup.isEmpty else { return }
        try await write { db in
            // 1. Sources — insert if absent (a shared source may still exist).
            for source in backup.sources where try !Source.exists(db, key: Self.key(source.id)) {
                try source.insert(db)
            }
            // 2. Assets — skip an id that already exists (idempotent) or a dedup key
            //    a live capture recreated (4A). Track which assets are now present
            //    so dependent rows only attach to real assets.
            var presentAssetKeys: Set<String> = []
            for asset in backup.assets {
                let assetKey = Self.key(asset.id)
                if try Asset.exists(db, key: assetKey) {
                    presentAssetKeys.insert(assetKey)
                    continue
                }
                if let dedup = asset.dedupKey,
                   try Asset.filter(Column("dedup_key") == dedup).fetchCount(db) > 0 {
                    continue // content re-created under a new id since the delete.
                }
                // The FK source must exist (inserted above, unless shared+present).
                guard try Source.exists(db, key: Self.key(asset.sourceId)) else { continue }
                try asset.insert(db)
                presentAssetKeys.insert(assetKey)
            }
            // 3. Memberships — the asset must be present, the collection must still
            //    exist, and no membership for (collection, asset) may already exist.
            for item in backup.memberships {
                guard presentAssetKeys.contains(Self.key(item.assetID)) else { continue }
                guard try Collection.exists(db, key: Self.key(item.collectionID)) else { continue }
                guard try Self.membership(
                    db, collectionID: item.collectionID, assetID: item.assetID) == nil else { continue }
                try item.insert(db)
            }
            // 4. Tag links — the asset must be present, the tag must still exist
            //    (tags survive a delete), and the link must be absent.
            for link in backup.tagLinks {
                guard presentAssetKeys.contains(Self.key(link.assetID)) else { continue }
                guard try Tag.exists(db, key: Self.key(link.tagID)) else { continue }
                let already = try AssetTag
                    .filter(Column("asset_id") == Self.key(link.assetID))
                    .filter(Column("tag_id") == Self.key(link.tagID))
                    .fetchCount(db) > 0
                if !already { try link.insert(db) }
            }
            // 5. Covers — restore only if the collection still has no cover (don't
            //    clobber a choice the user made after the delete).
            for cover in backup.covers {
                guard presentAssetKeys.contains(Self.key(cover.assetID)) else { continue }
                guard var collection = try Collection.fetchOne(
                    db, key: Self.key(cover.collectionID)) else { continue }
                if collection.coverAssetID == nil {
                    collection.coverAssetID = cover.assetID
                    collection.updatedAt = Date()
                    try collection.update(db)
                }
            }
        }
    }

    /// Every distinct non-null `blob_hash` an asset currently references — the
    /// "keep" set for the launch orphan-blob GC (010 · delete-undo).
    public func referencedBlobHashes() async throws -> Set<String> {
        try await read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT DISTINCT blob_hash FROM asset WHERE blob_hash IS NOT NULL"))
        }
    }

    /// Forget every `job_item` whose blob is among `orphanedHashes` and recompute the
    /// `ingested_count` of each job that loses rows — keeping the denormalized count
    /// drift-free, the same in-transaction invariant `recordJobItem` maintains. Shared
    /// by `deleteAssets` (reactive, on orphaning) and `reconcileOrphanedKnownItems`
    /// (proactive GC). Returns the distinct job keys touched. Must run inside a write.
    @discardableResult
    private static func forgetOrphanedKnownItems(
        _ orphanedHashes: [String], in db: Database
    ) throws -> Set<String> {
        var forgottenJobKeys: Set<String> = []
        for hash in orphanedHashes {
            let touched = try String.fetchAll(
                db, sql: "SELECT DISTINCT job_id FROM job_item WHERE blob_hash = ?",
                arguments: [hash])
            if !touched.isEmpty {
                try db.execute(
                    sql: "DELETE FROM job_item WHERE blob_hash = ?", arguments: [hash])
                forgottenJobKeys.formUnion(touched)
            }
        }
        for jobKey in forgottenJobKeys {
            let landed = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM job_item WHERE job_id = ? AND status IN (?, ?)
                """, arguments: [
                    jobKey,
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ]) ?? 0
            try db.execute(
                sql: "UPDATE job SET ingested_count = ? WHERE id = ?",
                arguments: [landed, jobKey])
        }
        return forgottenJobKeys
    }

    // MARK: - Reads (P16 — collection-scoped reads return full arrays)

    /// Every collection, ordered by `name` then `id` (stable). The library's
    /// collection count is small and bounded, so this returns the full
    /// inventory (P16 — only the unbounded library-wide reads are paged).
    public func listCollections() async throws -> [Collection] {
        try await read { db in
            // Flat `(name, id)` order — a stable, documented contract. Manual
            // sibling order (`sort_index`) is NOT applied here: the UI regroups
            // this flat list into the tree and sorts each parent group itself
            // (`FolderNode.tree` / `CollectionTargets`), so a global sort_index —
            // which repeats across parents — would be meaningless here anyway.
            try Collection.order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    /// One collection by id; `.notFound` if absent.
    public func getCollection(id: UUID) async throws -> Collection {
        try await read { db in
            guard let collection = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            return collection
        }
    }

    /// The P14 joined read for a collection — every membership with its full
    /// asset + source, mapped to the public GRDB-free ``CollectionItemDetail``
    /// (A2). Collection-scoped, so the FULL array is returned (P16 — the views
    /// need every item), which is why no keyset cursor is needed here.
    ///
    /// `sort` (007) selects the ORDER BY; the default `.manual` preserves the
    /// prior behaviour (drag order, source-compatible for existing callers):
    ///   • `.manual` → `collection_item.manual_order, collection_item.id`.
    ///   • `.newest` → `asset.created_at DESC, asset.id DESC`.
    ///   • `.mostViewed` → `asset.view_count DESC, asset.created_at DESC,
    ///     asset.id DESC` (view_count ties are the norm, so the newest/​id
    ///     tie-breaks keep the order deterministic).
    /// Switching modes never rewrites `manual_order`, so it is non-destructive.
    /// `.notFound` if the collection is absent.
    public func collectionItems(
        in collectionID: UUID, sort: SortMode = .manual
    ) async throws -> [CollectionItemDetail] {
        try await read { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            // CollectionItem ⋈ Asset ⋈ Source, all required (P14): one round-trip,
            // no N+1. GRDB qualifies bare base columns to `collection_item`, so
            // the asset-keyed orderings reference the joined `asset` table by
            // name to avoid picking the membership row's columns.
            var request = CollectionItem
                .filter(Column("collection_id") == Self.key(collectionID))
                .including(required: CollectionItem.asset
                    .including(required: Asset.source))
            switch sort {
            case .manual:
                request = request.order(Column("manual_order"), Column("id"))
            case .newest:
                request = request.order(sql: "asset.created_at DESC, asset.id DESC")
            case .mostViewed:
                request = request.order(
                    sql: "asset.view_count DESC, asset.created_at DESC, asset.id DESC")
            }
            return try CollectionItemRow.fetchAll(db, request).map {
                CollectionItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
        }
    }

    /// One asset with its required provenance; `.notFound` if absent. Metadata
    /// only (P16) — never the blob bytes.
    public func getAsset(id: UUID) async throws -> AssetDetail {
        try await read { db in
            let request = Asset
                .filter(Column("id") == Self.key(id))
                .including(required: Asset.source)
            guard let row = try AssetSourceRow.fetchOne(db, request) else {
                throw AtelierError.notFound(entity: "asset", id: id)
            }
            return AssetDetail(asset: row.asset, source: row.source)
        }
    }

    /// A batch cover lookup for the collections gallery (004-P2): each requested
    /// collection id that HAS a cover asset maps to that asset's `blob_hash` (so
    /// the UI can resolve the on-disk thumbnail). Collections with no cover — or
    /// a cover asset that was deleted (`SET NULL`) — are simply absent from the
    /// result. One joined round-trip; ids not present in the store are skipped.
    public func collectionCovers(_ ids: [UUID]) async throws -> [UUID: String] {
        let keys = ids.map(Self.key)
        guard !keys.isEmpty else { return [:] }
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT collection.id AS cid, asset.blob_hash AS hash
                FROM collection
                JOIN asset ON asset.id = collection.cover_asset_id
                WHERE collection.id IN (\(databaseQuestionMarks(count: keys.count)))
                  AND asset.blob_hash IS NOT NULL
                """, arguments: StatementArguments(keys))
            var covers: [UUID: String] = [:]
            for row in rows {
                guard let cid = UUID(uuidString: row["cid"]) else { continue }
                covers[cid] = row["hash"]
            }
            return covers
        }
    }

    /// Fanned "stack" previews for the Collections gallery cards (009 · N4): every
    /// ROOT collection, ordered `name, id` (stable, matching ``listCollections()``).
    /// Each entry carries the collection, its DIRECT item count, and the blob
    /// hashes of its `limit` most recently added byte-backed items (newest first)
    /// for the fanned thumbnails — one window-function query, not a per-collection
    /// N+1. Media-less kinds (003 · O1) have no thumbnail so they are skipped in
    /// the hashes but still counted; a collection with no byte-backed items simply
    /// fans nothing. `includeUnsorted` toggles the protected Unsorted root: the
    /// gallery shows a card for it, so it opts in.
    public func collectionStackPreviews(
        limit: Int = 3, includeUnsorted: Bool = false
    ) async throws -> [CollectionStackPreview] {
        try await read { db in
            var query = Collection.filter(Column("parent_collection_id") == nil)
            if !includeUnsorted {
                query = query.filter(Column("id") != Self.key(Collection.unsortedID))
            }
            let roots = try query
                .order(Column("name"), Column("id"))
                .fetchAll(db)
            guard !roots.isEmpty else { return [] }

            var counts: [UUID: Int] = [:]
            let countRows = try Row.fetchAll(db, sql: """
                SELECT collection_id AS cid, COUNT(*) AS cnt
                FROM collection_item GROUP BY collection_id
                """)
            for row in countRows {
                guard let cid = UUID(uuidString: row["cid"]) else { continue }
                counts[cid] = row["cnt"]
            }

            var hashes: [UUID: [String]] = [:]
            if limit > 0 {
                // `added_at DESC, id DESC` — the id tie-break keeps a
                // same-instant batch deterministic.
                let hashRows = try Row.fetchAll(db, sql: """
                    SELECT cid, hash FROM (
                        SELECT ci.collection_id AS cid, a.blob_hash AS hash,
                               ROW_NUMBER() OVER (
                                   PARTITION BY ci.collection_id
                                   ORDER BY ci.added_at DESC, ci.id DESC
                               ) AS rn
                        FROM collection_item ci
                        JOIN asset a ON a.id = ci.asset_id
                        WHERE a.blob_hash IS NOT NULL
                    ) WHERE rn <= ?
                    ORDER BY cid, rn
                    """, arguments: [limit])
                for row in hashRows {
                    guard let cid = UUID(uuidString: row["cid"]) else { continue }
                    hashes[cid, default: []].append(row["hash"])
                }
            }

            return roots.map {
                CollectionStackPreview(
                    collection: $0,
                    itemCount: counts[$0.id] ?? 0,
                    recentBlobHashes: hashes[$0.id] ?? [])
            }
        }
    }

    // MARK: - Spaces (005 · decision O1)

    /// Create a freeform space (005). Validates + trims the name (C8); the
    /// service generates `id` and `createdAt`/`updatedAt` (server-authoritative).
    @discardableResult
    public func createSpace(name: String) async throws -> Space {
        let trimmed = try Validation.spaceName(name)
        let now = Date()
        return try await write { db in
            // Append: the new space lands after the existing ones, keeping the flat
            // list dense at `0..<n` (043 · 2B, extended to spaces).
            var space = Space(id: UUID(), name: trimmed, createdAt: now, updatedAt: now)
            space.sortIndex = try Self.spaceIDsOrdered(in: db).count
            try space.insert(db)
            return space
        }
    }

    /// Rename a space. `.notFound` if absent; bumps `updatedAt`. (Spaces have no
    /// protected member, unlike the Unsorted folder.)
    @discardableResult
    public func renameSpace(id: UUID, to name: String) async throws -> Space {
        let trimmed = try Validation.spaceName(name)
        return try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            space.name = trimmed
            space.updatedAt = Date()
            try space.update(db)
            return space
        }
    }

    /// Set a space's cover (005 Q2). Both the space and the asset must exist
    /// (`.notFound`); bumps `updatedAt`.
    public func setSpaceCover(spaceID: UUID, assetID: UUID) async throws {
        try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            space.coverAssetID = assetID
            space.updatedAt = Date()
            try space.update(db)
        }
    }

    /// Delete a space; `.notFound` if absent. Its rows CASCADE at the DB level
    /// (schema O1) — asset rows and element rows alike; the underlying assets
    /// survive (only the placements go).
    public func deleteSpace(id: UUID) async throws {
        try await write { db in
            guard try Space.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            // Close the gap the delete left so the list stays dense (043 · 2B).
            try Self.applyDenseSpaceOrder(try Self.spaceIDsOrdered(in: db), in: db)
        }
    }

    /// Reposition a space in the flat manual order (043 · 2B, the space analog of
    /// ``moveCollection(id:toParent:index:)``). The space must exist (`.notFound`).
    /// `index` is the destination slot **with the moved space removed** (`0` =
    /// first, `nil` = append last); it is clamped to a valid range. The whole list
    /// is renumbered to a dense `0..<n`. Bumps `updatedAt` (a user-visible change).
    public func moveSpace(id: UUID, index: Int? = nil) async throws {
        try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            space.updatedAt = Date()
            try space.update(db)
            // The moved row still carries its stale index, so strip + reinsert at
            // the target slot rather than trust its position.
            var ordered = try Self.spaceIDsOrdered(in: db)
            ordered.removeAll { $0 == id }
            let target = min(max(index ?? ordered.count, 0), ordered.count)
            ordered.insert(id, at: target)
            try Self.applyDenseSpaceOrder(ordered, in: db)
        }
    }

    /// The space ids in canonical manual order — persisted `sort_index`, tie-broken
    /// by `(created_at DESC, id)` (matching ``listSpaces()``). The single seam used
    /// to renumber the list after a create / delete / move (043 · 2B).
    private static func spaceIDsOrdered(in db: Database) throws -> [UUID] {
        try Space
            .order(Column("sort_index"), Column("created_at").desc, Column("id"))
            .fetchAll(db).map(\.id)
    }

    /// Write a dense `0..<n` `sort_index` for `orderedIDs`, in order. A targeted
    /// column UPDATE (not a record `update`) so it does NOT bump `updated_at` — a
    /// renumber is structural bookkeeping, not a user edit. Mirrors the collection
    /// ``applyDenseOrder(_:in:)``.
    private static func applyDenseSpaceOrder(_ orderedIDs: [UUID], in db: Database) throws {
        for (position, id) in orderedIDs.enumerated() {
            try db.execute(
                sql: "UPDATE space SET sort_index = ? WHERE id = ?",
                arguments: [position, Self.key(id)])
        }
    }

    /// Delete a space AND capture a verbatim backup for undo, in ONE transaction
    /// (UX-batch · space-delete undo). Mirrors ``deleteAssetsRecoverable(_:)``: the
    /// space row and ALL its placements are read BEFORE the cascade runs, so the
    /// backup can't drift from what was deleted. The underlying assets are never
    /// touched, so ``restoreDeletedSpace(_:)`` reinstates the board exactly.
    public func deleteSpaceRecoverable(id: UUID) async throws -> DeletedSpaceBackup {
        try await write { db in
            guard let space = try Space.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            let items = try SpaceItem
                .filter(Column("space_id") == Self.key(id))
                .fetchAll(db)
            guard try Space.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            // Close the gap so the remaining spaces stay dense; the backup keeps
            // the deleted space's own `sortIndex` for `restoreDeletedSpace` (043 · 2B).
            try Self.applyDenseSpaceOrder(try Self.spaceIDsOrdered(in: db), in: db)
            return DeletedSpaceBackup(space: space, items: items)
        }
    }

    /// Reinstate a ``DeletedSpaceBackup`` verbatim — the inverse of
    /// ``deleteSpaceRecoverable(id:)``. ONE transaction, best-effort per row and
    /// idempotent (skip-if-exists), so a redo-after-undo can't duplicate. Ids /
    /// positions / z-order / timestamps are preserved. Resilient: the space's cover
    /// is nulled if that asset was deleted since, and any placement whose asset no
    /// longer exists is skipped (element rows always restore).
    public func restoreDeletedSpace(_ backup: DeletedSpaceBackup) async throws {
        guard let space = backup.space else { return }
        try await write { db in
            if try !Space.exists(db, key: Self.key(space.id)) {
                var restored = space
                // Don't reinstate a dangling cover FK (the asset may be gone).
                if let cover = restored.coverAssetID,
                   try !Asset.exists(db, key: Self.key(cover)) {
                    restored.coverAssetID = nil
                }
                try restored.insert(db)
                // Put it back at (close to) its former slot: reinsert at the stored
                // index among the now-dense survivors, then renumber (043 · 2B).
                var ordered = try Self.spaceIDsOrdered(in: db)
                ordered.removeAll { $0 == restored.id }
                let target = min(max(restored.sortIndex, 0), ordered.count)
                ordered.insert(restored.id, at: target)
                try Self.applyDenseSpaceOrder(ordered, in: db)
            }
            for item in backup.items {
                guard try !SpaceItem.exists(db, key: Self.key(item.id)) else { continue }
                if let assetID = item.assetID,
                   try !Asset.exists(db, key: Self.key(assetID)) {
                    continue // the placed asset was deleted since — skip its row.
                }
                try item.insert(db)
            }
        }
    }

    /// Every space in manual order — persisted `sort_index`, tie-broken by
    /// `(created_at DESC, id)` so equal indices (unmigrated fixtures) keep the prior
    /// newest-first order (043 · 2B). The space count is small and bounded, so this
    /// returns the full inventory (P16).
    public func listSpaces() async throws -> [Space] {
        try await read { db in
            try Space
                .order(Column("sort_index"), Column("created_at").desc, Column("id"))
                .fetchAll(db)
        }
    }

    /// A batch cover lookup for the Spaces list (005 Q2), symmetric to
    /// ``collectionCovers(_:)``: each requested space id that HAS a (surviving)
    /// cover asset maps to that asset's `blob_hash`. Spaces with no cover are
    /// absent from the result.
    public func spaceCovers(_ ids: [UUID]) async throws -> [UUID: String] {
        let keys = ids.map(Self.key)
        guard !keys.isEmpty else { return [:] }
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT space.id AS sid, asset.blob_hash AS hash
                FROM space
                JOIN asset ON asset.id = space.cover_asset_id
                WHERE space.id IN (\(databaseQuestionMarks(count: keys.count)))
                  AND asset.blob_hash IS NOT NULL
                """, arguments: StatementArguments(keys))
            var covers: [UUID: String] = [:]
            for row in rows {
                guard let sid = UUID(uuidString: row["sid"]) else { continue }
                covers[sid] = row["hash"]
            }
            return covers
        }
    }

    /// Fanned "stack" previews for the Home Spaces cards (009 · N4), the space
    /// analog of ``collectionStackPreviews(limit:includeUnsorted:)``: every space,
    /// in manual order (`sort_index`, tie-broken `created_at DESC, id` — matching
    /// ``listSpaces()`` so Home and the sidebar share ONE order). Each entry carries
    /// the space, its placed-item count, and the blob hashes of its `limit` most
    /// recently added asset items (newest first) for the fan — one window-function
    /// query, not a per-space N+1. Element rows (NULL `asset_id`) and media-less
    /// assets have no thumbnail so they are skipped in the hashes but still counted;
    /// a space with no byte-backed items simply fans nothing.
    public func spaceStackPreviews(limit: Int = 3) async throws -> [SpaceStackPreview] {
        try await read { db in
            let spaces = try Space
                .order(Column("sort_index"), Column("created_at").desc, Column("id"))
                .fetchAll(db)
            guard !spaces.isEmpty else { return [] }

            var counts: [UUID: Int] = [:]
            let countRows = try Row.fetchAll(db, sql: """
                SELECT space_id AS sid, COUNT(*) AS cnt
                FROM space_item GROUP BY space_id
                """)
            for row in countRows {
                guard let sid = UUID(uuidString: row["sid"]) else { continue }
                counts[sid] = row["cnt"]
            }

            var hashes: [UUID: [String]] = [:]
            if limit > 0 {
                // `created_at DESC, id DESC` — the id tie-break keeps a
                // same-instant batch deterministic.
                let hashRows = try Row.fetchAll(db, sql: """
                    SELECT sid, hash FROM (
                        SELECT si.space_id AS sid, a.blob_hash AS hash,
                               ROW_NUMBER() OVER (
                                   PARTITION BY si.space_id
                                   ORDER BY si.created_at DESC, si.id DESC
                               ) AS rn
                        FROM space_item si
                        JOIN asset a ON a.id = si.asset_id
                        WHERE a.blob_hash IS NOT NULL
                    ) WHERE rn <= ?
                    ORDER BY sid, rn
                    """, arguments: [limit])
                for row in hashRows {
                    guard let sid = UUID(uuidString: row["sid"]) else { continue }
                    hashes[sid, default: []].append(row["hash"])
                }
            }

            return spaces.map {
                SpaceStackPreview(
                    space: $0,
                    itemCount: counts[$0.id] ?? 0,
                    recentBlobHashes: hashes[$0.id] ?? [])
            }
        }
    }

    /// One space by id; `.notFound` if absent.
    public func getSpace(id: UUID) async throws -> Space {
        try await read { db in
            guard let space = try Space.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            return space
        }
    }

    /// Place an asset on a space (005). Validates the placement finite/positive
    /// (C8) and the discriminator (an asset row requires the id); the space and
    /// asset must exist (`.notFound`). Returns the created ``SpaceItem``. The same
    /// asset MAY be added twice (each row has its own id) — a deliberate caller
    /// act, mirroring `addAssets`.
    @discardableResult
    public func addAssetToSpace(
        assetID: UUID, to spaceID: UUID,
        x: Double, y: Double, w: Double, h: Double, z: Int
    ) async throws -> SpaceItem {
        try Validation.spaceItem(kind: .asset, assetID: assetID)
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        let now = Date()
        let item = SpaceItem(
            id: UUID(), spaceID: spaceID, kind: .asset, assetID: assetID,
            x: x, y: y, w: w, h: h, z: z, style: nil, createdAt: now, updatedAt: now)
        return try await write { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            try item.insert(db)
            return item
        }
    }

    /// Add a freeform element (frame / text) to a space (005 O1; wired by E3).
    /// Validates the placement (C8) and the discriminator (an element row must
    /// NOT carry an asset id); the space must exist (`.notFound`). `style` is the
    /// element's ``ElementStyle`` and is stored as JSON TEXT.
    @discardableResult
    public func addElement(
        to spaceID: UUID, kind: SpaceItemKind, style: ElementStyle?,
        x: Double, y: Double, w: Double, h: Double, z: Int
    ) async throws -> SpaceItem {
        try Validation.spaceItem(kind: kind, assetID: nil)
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        let now = Date()
        let item = SpaceItem(
            id: UUID(), spaceID: spaceID, kind: kind, assetID: nil,
            x: x, y: y, w: w, h: h, z: z, style: style?.jsonString(),
            createdAt: now, updatedAt: now)
        return try await write { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            try item.insert(db)
            return item
        }
    }

    /// Move / resize a space item, keeping its kind + style. Validates the
    /// placement (C8); `.notFound` if the row is absent. Bumps `updatedAt`.
    public func setSpaceItemPlacement(
        itemID: UUID, x: Double, y: Double, w: Double, h: Double, z: Int
    ) async throws {
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        try await write { db in
            guard var item = try SpaceItem.fetchOne(db, key: Self.key(itemID)) else {
                throw AtelierError.notFound(entity: "space_item", id: itemID)
            }
            item.x = x; item.y = y; item.w = w; item.h = h; item.z = z
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Restyle a freeform element (005; wired by E3). `.notFound` if absent;
    /// bumps `updatedAt`. Stores the ``ElementStyle`` as JSON TEXT (nil clears it).
    public func updateSpaceItemStyle(itemID: UUID, style: ElementStyle?) async throws {
        try await write { db in
            guard var item = try SpaceItem.fetchOne(db, key: Self.key(itemID)) else {
                throw AtelierError.notFound(entity: "space_item", id: itemID)
            }
            item.style = style?.jsonString()
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Remove one row from a space (a placement, not the asset). Idempotent — an
    /// unknown / already-removed id is a no-op, not an error.
    public func removeSpaceItem(itemID: UUID) async throws {
        try await write { db in
            _ = try SpaceItem.deleteOne(db, key: Self.key(itemID))
        }
    }

    /// Re-insert a full ``SpaceItem`` row **verbatim** — the inverse of
    /// ``removeSpaceItem(itemID:)`` and the primitive undo/redo uses to restore a
    /// deleted row or re-create an undone one with its **id preserved** (so the
    /// undo chain stays stable). Validates the discriminator (C8) + placement; the
    /// space (and, for an asset row, the asset) must exist (`.notFound`). A no-op
    /// on an id that already exists (idempotent redo).
    public func restoreSpaceItem(_ item: SpaceItem) async throws {
        try Validation.spaceItem(kind: item.kind, assetID: item.assetID)
        try Validation.canvasPlacement(x: item.x, y: item.y, w: item.w, h: item.h)
        try await write { db in
            guard try Space.exists(db, key: Self.key(item.spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: item.spaceID)
            }
            if let assetID = item.assetID {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
            }
            guard try !SpaceItem.exists(db, key: Self.key(item.id)) else { return }
            try item.insert(db)
        }
    }

    /// The space's board: every row with its media (asset rows carry the full
    /// ``Asset`` + ``Source``; element rows carry neither), ordered by `z` then
    /// `id` so draw order is stable. Space-scoped, so the FULL array is returned
    /// (P16). `.notFound` if the space is absent.
    public func spaceItems(in spaceID: UUID) async throws -> [SpaceItemDetail] {
        try await read { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            // SpaceItem ⟕ Asset ⟕ Source: BOTH joins are OPTIONAL (LEFT) —
            // element rows have a NULL asset_id. The nested source must also be
            // optional: GRDB forbids chaining a required association behind an
            // optional one. An asset row's source is NOT NULL by schema (C6), so
            // it is still populated for every asset row. One round-trip, no N+1.
            let request = SpaceItem
                .filter(Column("space_id") == Self.key(spaceID))
                .including(optional: SpaceItem.asset
                    .including(optional: Asset.source))
                .order(Column("z"), Column("id"))
            return try SpaceItemRow.fetchAll(db, request).map {
                SpaceItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
        }
    }

    // MARK: - Search (P16 bounded + FTS5)

    /// Search assets library-wide, bounded (P16) and keyset-paged.
    ///
    /// - `text`: when non-nil/non-empty, full-text matched (with a type-ahead
    ///   PREFIX on the final term, see ``ftsMatchQuery(_:)``) against the source
    ///   provenance (`source_fts`), the asset's own content INCLUDING its
    ///   user-given `name` / `note` (`asset_fts`, 044/045 · 1A), and OCR text
    ///   inside images (`analysis_fts`); a CONTAINS match also folds in tag names
    ///   and collection names so free text finds an item by the tag it carries or
    ///   the collection it lives in. For queries ≥3 chars (and without a trailing
    ///   space, which signals a finished word), the SHORT human fields (title /
    ///   author / name / tag / collection) also SUBSTRING-match via trigram
    ///   (046 Phase 2, see ``trigramMatchQuery(_:)``) — "air" finds "chair". When
    ///   nil/blank, lists all assets (optionally platform-filtered) — bounded.
    /// - `platform`: optional filter on the asset's source.
    /// - `tagIDs`: optional structured tag filter (007 · S1). Empty → no tag
    ///   conjunct. `tagMatch` chooses set semantics: `.all` requires EVERY tag
    ///   (dup-join-safe via `COUNT(DISTINCT tag_id) = N`), `.any` requires one.
    ///   Tag text never enters FTS — the caller resolves names → ids first.
    /// - `tagNameContains`: optional `tag:`-style filter (044/045 · 17A) — an
    ///   AND conjunct restricting to assets carrying a tag whose name CONTAINS the
    ///   needle (normalized `#`-stripped, like `tagIDs` names). Composes WITH
    ///   `tagIDs` (both must hold). Blank/`#`-only → no conjunct.
    /// - `collectionIDs`: optional scope (044/045 · 16A) — restrict to assets that
    ///   are members of ANY listed collection (OR across the ids). Empty → whole
    ///   library, no scope.
    /// - `sort`: `.newest` (default) orders `created_at DESC, id DESC` — the
    ///   stable order the keyset cursor is defined on. `.relevance` orders by
    ///   best-of-arms `bm25()` (044/045 · 3A) and is NOT pageable (see `after`).
    /// - `limit` is clamped to `1...500`; at most `limit` rows are returned.
    /// - `after`: a keyset cursor (P16) — only rows STRICTLY after it in the
    ///   `.newest` order are returned, so paging never drifts or repeats as new
    ///   assets land (no OFFSET). Pairing a cursor with `.relevance` throws
    ///   ``AtelierError/relevanceSortUnpageable`` (relevance isn't that order).
    ///
    /// Returns ``AssetDetail`` (asset + source) — metadata only, never blob
    /// bytes (P16).
    public func searchAssets(
        text: String? = nil,
        platform: Platform? = nil,
        tagIDs: [UUID] = [],
        tagMatch: TagMatch = .all,
        tagNameContains: String? = nil,
        collectionIDs: [UUID] = [],
        sort: SearchSort = .newest,
        limit: Int = 50,
        after cursor: AssetPageCursor? = nil
    ) async throws -> [AssetDetail] {
        // Relevance order isn't the stable `(created_at, id)` sequence the keyset
        // cursor seeks into, so a cursor into it is meaningless (044/045 · 3A).
        // Reject explicitly rather than silently return a wrong/duplicated page.
        if sort == .relevance, cursor != nil {
            throw AtelierError.relevanceSortUnpageable
        }

        let clampedLimit = min(max(limit, 1), 500)
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !(trimmedText?.isEmpty ?? true)
        // The FTS5 MATCH string is built from the RAW (untrimmed) text so the
        // trailing-whitespace signal survives — `ftsMatchQuery` reads it to decide
        // whether the final term is a type-ahead prefix or a finished exact word
        // (5A/14A). `nil` when there's no text to match. Computed once and reused
        // by both the filter arm and the relevance ordering (no recompute drift).
        let ftsMatch = hasText ? Self.ftsMatchQuery(text ?? "") : nil
        // Trigram substring match (046 Phase 2). `nil` when substring search is off:
        //   • trailing whitespace — the same FINISHED-word signal `ftsMatchQuery`
        //     reads (5A): "typo " means the word is done → EXACT, so no substring
        //     arm (else "typo " would still surface "Typography"); OR
        //   • no term is ≥3 chars (trigram needs a 3-char window) — short queries
        //     keep the unicode61 prefix / LIKE fallback.
        // Computed once from the trimmed text, reused by the free-text arms and the
        // relevance ordering. The tag arm re-derives its own trigram from the
        // `#`-normalized needle (gated on this being enabled).
        let trailingSpace = text?.last?.isWhitespace ?? false
        let trigramMatch = (hasText && !trailingSpace)
            ? Self.trigramMatchQuery(trimmedText ?? "") : nil
        // Distinct ids only — a caller passing the same tag twice must not skew
        // the `.all` HAVING COUNT (that counts DISTINCT tag_id anyway, but the N
        // it is compared against must match the distinct set).
        let distinctTagIDs = Array(Set(tagIDs))
        let distinctCollectionIDs = Array(Set(collectionIDs))
        return try await read { db in
            // The source is required and carries the platform filter when given,
            // so the included join doubles as the filter (inner join).
            var sourceAssociation = Asset.source
            if let platform {
                sourceAssociation = sourceAssociation.filter(
                    Column("platform") == platform.rawValue)
            }
            var request = Asset.including(required: sourceAssociation)

            // FTS5: an asset MATCHes when its PROVENANCE matches `source_fts`
            // (title/author) OR its own CONTENT matches `asset_fts` (003 · O1 —
            // a tweet's text, a link's title/description, a color's name/hex, plus
            // the user-given `name`/`note`, 1A) OR the text INSIDE it matches
            // `analysis_fts` (012 · I2 — OCR of screenshots / type specimens).
            // Three external-content indices, kept separate (provenance vs content
            // vs derived OCR) and OR-combined here so both media-less items and
            // image-only text are findable by substance. Each subquery maps
            // `*_fts.rowid` → the base table's rowid → id.
            //
            // Substring arms (046 Phase 2): title / author (`source_trigram`) and
            // the user-given name (`asset_trigram`) fold in as ADDITIONAL OR arms
            // when the query is trigram-eligible (every term ≥3 chars), so a
            // mid-word "air" surfaces "chair" while the unicode61 arms above still
            // rank whole-word / prefix hits by bm25.
            //
            // Tag names and collection names (in no unicode61 index) fold in via a
            // final CONTAINS arm each: `*_trigram MATCH` when trigram-eligible,
            // else the leading-wildcard LIKE fallback for 1–2 char queries. The tag
            // needle is normalized the way tags are (`#` stripped), so "sf" / "#sf"
            // both find a tag stored as "sf"; a `#`-only query normalizes to empty
            // and drops that arm (no match-everything).
            if let trimmedText, !trimmedText.isEmpty, let match = ftsMatch {
                let tagNeedle = Validation.normalizedTagName(trimmedText)
                // Gated on trigram being enabled overall (respects trailing space),
                // then on the `#`-stripped needle's own ≥3-char eligibility.
                let tagTrigram = (trigramMatch != nil && !tagNeedle.isEmpty)
                    ? Self.trigramMatchQuery(tagNeedle) : nil
                var sql = """
                    source_id IN (
                        SELECT source.id FROM source
                        JOIN source_fts ON source_fts.rowid = source.rowid
                        WHERE source_fts MATCH ?
                     )
                     OR asset.id IN (
                        SELECT a.id FROM asset a
                        JOIN asset_fts ON asset_fts.rowid = a.rowid
                        WHERE asset_fts MATCH ?
                     )
                     OR asset.id IN (
                        SELECT an.asset_id FROM asset_analysis an
                        JOIN analysis_fts ON analysis_fts.rowid = an.rowid
                        WHERE analysis_fts MATCH ?
                     )
                    """
                var args: [String] = [match, match, match]

                // Direct-field substring arms (only when trigram-eligible).
                if let trigramMatch {
                    sql += """
                    \n OR source_id IN (
                        SELECT s.id FROM source s
                        JOIN source_trigram ON source_trigram.rowid = s.rowid
                        WHERE source_trigram MATCH ?
                     )
                     OR asset.id IN (
                        SELECT a.id FROM asset a
                        JOIN asset_trigram ON asset_trigram.rowid = a.rowid
                        WHERE asset_trigram MATCH ?
                     )
                    """
                    args.append(trigramMatch); args.append(trigramMatch)
                }

                // Collection-name CONTAINS arm: trigram, else LIKE fallback.
                if let trigramMatch {
                    sql += """
                    \n OR asset.id IN (
                        SELECT ci.asset_id FROM collection_item ci
                        JOIN collection c ON c.id = ci.collection_id
                        JOIN collection_trigram ON collection_trigram.rowid = c.rowid
                        WHERE collection_trigram MATCH ?
                     )
                    """
                    args.append(trigramMatch)
                } else {
                    sql += """
                    \n OR asset.id IN (
                        SELECT ci.asset_id FROM collection_item ci
                        JOIN collection c ON c.id = ci.collection_id
                        WHERE c.name LIKE ? ESCAPE '\\'
                     )
                    """
                    args.append(Self.containsPattern(trimmedText))
                }

                // Tag-name CONTAINS arm: trigram, else LIKE fallback (normalized).
                if !tagNeedle.isEmpty {
                    if let tagTrigram {
                        sql += """
                        \n OR asset.id IN (
                            SELECT atag.asset_id FROM asset_tag atag
                            JOIN tag ON tag.id = atag.tag_id
                            JOIN tag_trigram ON tag_trigram.rowid = tag.rowid
                            WHERE tag_trigram MATCH ?
                         )
                        """
                        args.append(tagTrigram)
                    } else {
                        sql += """
                        \n OR asset.id IN (
                            SELECT atag.asset_id FROM asset_tag atag
                            JOIN tag ON tag.id = atag.tag_id
                            WHERE tag.name LIKE ? ESCAPE '\\'
                         )
                        """
                        args.append(Self.containsPattern(tagNeedle))
                    }
                }
                request = request.filter(sql: "(\(sql))",
                                         arguments: StatementArguments(args))
            }

            // `tag:`-style name filter (044/045 · 17A): an AND conjunct (composes
            // with the structured `tagIDs` — both must hold), restricting to
            // assets carrying a tag whose name CONTAINS the needle. Normalized
            // like tag names; blank / `#`-only → no conjunct.
            if let tagNameContains {
                let needle = Validation.normalizedTagName(tagNameContains)
                if !needle.isEmpty {
                    if let tagTrigram = Self.trigramMatchQuery(needle) {
                        request = request.filter(sql: """
                            asset.id IN (
                                SELECT atag.asset_id FROM asset_tag atag
                                JOIN tag ON tag.id = atag.tag_id
                                JOIN tag_trigram ON tag_trigram.rowid = tag.rowid
                                WHERE tag_trigram MATCH ?
                            )
                            """, arguments: [tagTrigram])
                    } else {
                        request = request.filter(sql: """
                            asset.id IN (
                                SELECT atag.asset_id FROM asset_tag atag
                                JOIN tag ON tag.id = atag.tag_id
                                WHERE tag.name LIKE ? ESCAPE '\\'
                            )
                            """, arguments: [Self.containsPattern(needle)])
                    }
                }
            }

            // Collection scope (007 · S3 / 044/045 · 16A): membership subquery,
            // OR across the listed collections. Composes as a plain conjunct, so
            // it AND-combines with FTS / tags / platform. Empty → no scope.
            if !distinctCollectionIDs.isEmpty {
                let placeholders = databaseQuestionMarks(count: distinctCollectionIDs.count)
                let keys = distinctCollectionIDs.map(Self.key)
                // Qualify `asset.id` — the source join makes a bare `id` ambiguous.
                request = request.filter(sql: """
                    asset.id IN (SELECT asset_id FROM collection_item WHERE collection_id IN (\(placeholders)))
                    """, arguments: StatementArguments(keys))
            }

            // Structured tag filter (007 · S1). `.any` — a single IN subquery.
            // `.all` — GROUP BY … HAVING COUNT(DISTINCT tag_id) = N enforces that
            // the asset carries every listed tag, dup-join-safe.
            if !distinctTagIDs.isEmpty {
                let placeholders = databaseQuestionMarks(count: distinctTagIDs.count)
                let keys = distinctTagIDs.map(Self.key)
                switch tagMatch {
                case .any:
                    request = request.filter(sql: """
                        asset.id IN (SELECT asset_id FROM asset_tag WHERE tag_id IN (\(placeholders)))
                        """, arguments: StatementArguments(keys))
                case .all:
                    request = request.filter(sql: """
                        asset.id IN (
                            SELECT asset_id FROM asset_tag
                            WHERE tag_id IN (\(placeholders))
                            GROUP BY asset_id
                            HAVING COUNT(DISTINCT tag_id) = ?
                        )
                        """, arguments: StatementArguments(keys + [distinctTagIDs.count]))
                }
            }

            // Keyset seek: rows strictly after the cursor in the DESC order.
            // GRDB qualifies these `Column`s to the base `asset` table; the Date
            // binds to the same sortable text encoding the column stores (C5).
            // (Guarded to `.newest` above — relevance never reaches here.)
            if let cursor {
                request = request.filter(
                    Column("created_at") < cursor.createdAt
                    || (Column("created_at") == cursor.createdAt
                        && Column("id") < Self.key(cursor.id)))
            }

            request = Self.ordered(request, by: sort, match: ftsMatch,
                                   trigramMatch: trigramMatch)
                .limit(clampedLimit)

            return try AssetSourceRow.fetchAll(db, request).map {
                AssetDetail(asset: $0.asset, source: $0.source)
            }
        }
    }

    /// Apply the ``SearchSort`` ordering to a built search request (044/045 · 3A).
    ///
    /// `.newest` (and `.relevance` with no `match` — nothing to rank) → the stable
    /// `created_at DESC, id DESC` recency order. `.relevance` with text → a
    /// correlated best-of-arms score, ascending (lower = better), `id` as a
    /// deterministic tiebreak.
    ///
    /// The score is a scalar subquery over the same arms the WHERE clause filters
    /// on, taking the `MIN` (best) across whichever matched. Raw `bm25()` is NOT
    /// comparable across different FTS tables (each normalizes to its own column
    /// count / average document length), so an OCR hit in a long scan could
    /// otherwise outrank a title hit. We therefore TIER the arms with explicit
    /// additive bases (lower base = stronger signal), and let `bm25()` order
    /// finely WITHIN the primary tier:
    ///
    ///   • tier 0  — a WHOLE-WORD / prefix hit in provenance (`source_fts`) or the
    ///     item's own content + user-given name/note (`asset_fts`): `bm25`.
    ///   • tier `substringBase` — a SUBSTRING-only hit: a direct-field trigram
    ///     match (`source_trigram` title/author, `asset_trigram` name) OR an
    ///     indirect tag-/collection-name match (trigram or the <3-char LIKE
    ///     fallback). A flat neutral score above every tier-0 hit (046 · 4A).
    ///   • tier `ocrBase` — derived OCR (`analysis_fts`): `bm25` shifted so even
    ///     the best OCR hit ranks below any word OR substring field match.
    ///
    /// The direct-field trigram arms are listed EXPLICITLY (not left to the
    /// `COALESCE` fallback) so a row that matches BOTH a name substring and OCR
    /// still scores `substringBase`, not `ocrBase` — a substring name hit must
    /// outrank OCR. Indirect tag/collection substring hits rely on the fallback
    /// (matching Phase 1's LIKE-tier precedent). The trigram arms are present only
    /// when `trigramMatch` is non-nil (the query is ≥3-char eligible).
    ///
    /// `substringBase`/`ocrBase` are chosen far above the bm25 range (always
    /// > -1000) so the tiers never interleave. `COALESCE(…, substringBase)` scores
    /// a row that matched ONLY via an indirect / fallback arm; a row with no scored
    /// arm can't reach here (it wouldn't have passed the WHERE). Correlation is by
    /// scalar subquery on the base `asset` alias, independent of the join alias.
    private static func ordered(
        _ request: QueryInterfaceRequest<Asset>,
        by sort: SearchSort,
        match: String?,
        trigramMatch: String?
    ) -> QueryInterfaceRequest<Asset> {
        guard sort == .relevance, let match else {
            return request.order(Column("created_at").desc, Column("id").desc)
        }
        let substringBase = 1_000_000.0   // above any bm25; below OCR.
        let ocrBase = 2_000_000.0         // OCR always ranks last among the hits.

        // Tier-0 word arms (always) + the analysis/OCR arm; the direct-field
        // trigram arms slot in only when the query is trigram-eligible.
        var arms = [
            """
            SELECT bm25(source_fts) AS score FROM source_fts
                WHERE source_fts MATCH ?
                  AND source_fts.rowid = (SELECT rowid FROM source WHERE source.id = asset.source_id)
            """,
            """
            SELECT bm25(asset_fts) FROM asset_fts
                WHERE asset_fts MATCH ? AND asset_fts.rowid = asset.rowid
            """,
        ]
        var args: [String] = [match, match]
        if let trigramMatch {
            arms.append("""
                SELECT \(substringBase) FROM source_trigram
                    WHERE source_trigram MATCH ?
                      AND source_trigram.rowid = (SELECT rowid FROM source WHERE source.id = asset.source_id)
                """)
            arms.append("""
                SELECT \(substringBase) FROM asset_trigram
                    WHERE asset_trigram MATCH ? AND asset_trigram.rowid = asset.rowid
                """)
            args.append(trigramMatch); args.append(trigramMatch)
        }
        arms.append("""
            SELECT \(ocrBase) + bm25(analysis_fts) FROM analysis_fts
                WHERE analysis_fts MATCH ?
                  AND analysis_fts.rowid = (SELECT rowid FROM asset_analysis WHERE asset_analysis.asset_id = asset.id)
            """)
        args.append(match)

        let union = arms.joined(separator: "\n UNION ALL \n")
        return request.order(sql: """
            COALESCE((SELECT MIN(score) FROM (\(union))), \(substringBase)) ASC, asset.id ASC
            """, arguments: StatementArguments(args))
    }

    // MARK: - Asset details (041 · Name / Note / Collections)

    /// Set (or clear) an asset's user-given display name. Trims; an empty result
    /// stores `NULL` (the "unnamed" state). `.notFound` if the asset is absent.
    /// Through the write funnel.
    public func setName(_ name: String?, for assetID: UUID) async throws {
        try await write { db in
            guard var asset = try Asset.fetchOne(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            asset.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try asset.update(db)
        }
    }

    /// Set (or clear) an asset's free-form note. Trims; empty → `NULL`.
    /// `.notFound` if the asset is absent. Through the write funnel.
    public func setNote(_ note: String?, for assetID: UUID) async throws {
        try await write { db in
            guard var asset = try Asset.fetchOne(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            asset.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try asset.update(db)
        }
    }

    /// The collections an asset is a direct member of, name-ordered — the reverse
    /// of ``addAssets(_:to:)``. Powers the Item Detail "Collections" chips; kept
    /// off the joined grid read (``collectionItems``) so the hot path stays a
    /// single round-trip. Empty if the asset has no memberships.
    public func collections(for assetID: UUID) async throws -> [Collection] {
        try await read { db in
            let collectionIDs = try CollectionItem
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchAll(db)
                .map(\.collectionID)
            guard !collectionIDs.isEmpty else { return [] }
            let keys = collectionIDs.map(Self.key)
            return try Collection
                .filter(keys.contains(Column("id")))
                .order(Column("name"), Column("id"))
                .fetchAll(db)
        }
    }

    // MARK: - Tags (schema-reserved; the agent interface needs these)

    /// Apply a tag to an asset. Validates + trims the name (C8); finds-or-creates
    /// the `(name, source)` tag, then links it idempotently (no duplicate join
    /// row). `.notFound` if the asset is absent. Through the write funnel.
    @discardableResult
    public func applyTag(_ name: String, to assetID: UUID, source: TagSource) async throws -> Tag {
        let trimmed = try Validation.tagName(name)
        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            // Find-or-create by (name, source): user vs agent tags are distinct.
            let tag: Tag
            if let existing = try Tag
                .filter(Column("name") == trimmed)
                .filter(Column("source") == source.rawValue)
                .fetchOne(db) {
                tag = existing
            } else {
                let created = Tag(id: UUID(), name: trimmed, source: source)
                try created.insert(db)
                tag = created
            }
            // Idempotent link — skip if the join row already exists.
            let linked = try AssetTag
                .filter(Column("asset_id") == Self.key(assetID))
                .filter(Column("tag_id") == Self.key(tag.id))
                .fetchCount(db) > 0
            if !linked {
                try AssetTag(assetID: assetID, tagID: tag.id).insert(db)
            }
            return tag
        }
    }

    /// Remove a tag from an asset. Idempotent — a no-op if the tag or the link
    /// is absent (the tag row itself is left intact for other assets). Through
    /// the write funnel.
    public func removeTag(_ name: String, from assetID: UUID, source: TagSource) async throws {
        // Same normalization as apply — so removing by a typed "#sf" matches the
        // stored "sf" (chips already pass the normalized name; this is robustness).
        let trimmed = Validation.normalizedTagName(name)
        try await write { db in
            guard let tag = try Tag
                .filter(Column("name") == trimmed)
                .filter(Column("source") == source.rawValue)
                .fetchOne(db) else { return }
            try AssetTag
                .filter(Column("asset_id") == Self.key(assetID))
                .filter(Column("tag_id") == Self.key(tag.id))
                .deleteAll(db)
        }
    }

    /// An asset's tags, ordered by `name` then `id` (stable). Read.
    public func tags(for assetID: UUID) async throws -> [Tag] {
        try await read { db in
            try Tag
                .filter(sql: "id IN (SELECT tag_id FROM asset_tag WHERE asset_id = ?)",
                        arguments: [Self.key(assetID)])
                .order(Column("name"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Every tag in the library, ordered `name, source, id` (stable). Small,
    /// bounded inventory (P16) — feeds the search token vocabulary. Includes both
    /// `.user` and `.agent` tags; the caller distinguishes by ``Tag/source``.
    public func allTags() async throws -> [Tag] {
        try await read { db in
            try Tag.order(Column("name"), Column("source"), Column("id")).fetchAll(db)
        }
    }

    /// The search token vocabulary (007 · S3): tags whose `name` case-insensitively
    /// begins with `prefix`, ordered `name, source, id` and limited. A blank
    /// prefix returns the first `limit` tags overall (initial suggestions). Both
    /// sources are included so agent tags remain filterable (distinguished by the
    /// caller). `limit` is clamped to `1...200`.
    public func tagVocabulary(prefix: String, limit: Int = 50) async throws -> [Tag] {
        let clampedLimit = min(max(limit, 1), 200)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await read { db in
            var request = Tag.all()
            if !trimmed.isEmpty {
                // LIKE is case-insensitive for ASCII by default; escape the LIKE
                // wildcards in the user's prefix so `%`/`_` match literally.
                let pattern = Self.escapeLikePrefix(trimmed) + "%"
                request = request.filter(sql: "name LIKE ? ESCAPE '\\'", arguments: [pattern])
            }
            return try request
                .order(Column("name"), Column("source"), Column("id"))
                .limit(clampedLimit)
                .fetchAll(db)
        }
    }

    // MARK: - Bulk-import jobs (015 · decision 3A ledger)

    /// Open a new bulk-import sweep. The service owns `id` / `createdAt` /
    /// `updatedAt` and starts the sweep `open` with a zero `ingestedCount`. The
    /// extension tags each subsequent item POST with the returned id.
    @discardableResult
    public func createJob(
        platform: Platform, scope: String? = nil, totalEstimate: Int? = nil
    ) async throws -> Job {
        let now = Date()
        let job = Job(
            id: UUID(), platform: platform, scope: scope, status: .open,
            totalEstimate: totalEstimate, ingestedCount: 0,
            createdAt: now, updatedAt: now)
        return try await write { db in
            try job.insert(db)
            return job
        }
    }

    /// Record (or re-record) one enumerated item's outcome, in ONE transaction
    /// (P15). Upsert on the `(job_id, source_id)` PK makes a retried record
    /// idempotent — the resumable-sweep invariant. In the SAME transaction the
    /// job's `ingested_count` is RECOMPUTED from the `job_item` rows (not
    /// incremented), so a crash between items leaves the counter exactly
    /// consistent with the committed items — no drift, ever (7A/11A). `.notFound`
    /// if the job is absent.
    @discardableResult
    public func recordJobItem(
        jobID: UUID, sourceID: String, sourceURL: String? = nil,
        status: JobItemStatus, blobHash: String? = nil
    ) async throws -> JobItem {
        let now = Date()
        let item = JobItem(
            jobID: jobID, sourceID: sourceID, sourceURL: sourceURL,
            status: status, blobHash: blobHash, updatedAt: now)
        return try await write { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            // Upsert by composite PK (explicit over clever — matches the codebase's
            // fetch-then-insert/update idiom rather than relying on save() semantics).
            let exists = try JobItem
                .filter(Column("job_id") == Self.key(jobID))
                .filter(Column("source_id") == sourceID)
                .fetchCount(db) > 0
            if exists { try item.update(db) } else { try item.insert(db) }

            // Recompute the denormalized progress counter from the source of truth
            // in the same transaction (no drift on crash / re-record).
            let landed = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM job_item WHERE job_id = ? AND status IN (?, ?)
                """, arguments: [
                    Self.key(jobID),
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ]) ?? 0
            try db.execute(
                sql: "UPDATE job SET ingested_count = ?, updated_at = ? WHERE id = ?",
                arguments: [landed, now, Self.key(jobID)])
            return item
        }
    }

    /// The set of platform source ids already ingested for this job's platform,
    /// across ALL jobs (P14 download-skip). A source is "known" (its bytes are in
    /// the store, so the extension must NOT re-download it) only when some
    /// `job_item` for the SAME platform reached `ingested` or `deduped` — a
    /// `retryableFailed`/`permanentFailed`/`skipped` item is not itself proof the
    /// bytes exist. Scoped by platform so a tweet id can never mask a pin id.
    /// `.notFound` if the job is absent. Content-addressing remains the
    /// authoritative dedup backstop; this only avoids the costly re-download.
    public func knownSourceIDs(forJob jobID: UUID) async throws -> Set<String> {
        try await read { db in
            guard let platform = try String.fetchOne(
                db, sql: "SELECT platform FROM job WHERE id = ?",
                arguments: [Self.key(jobID)]) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return try String.fetchSet(db, sql: """
                SELECT DISTINCT job_item.source_id
                FROM job_item
                JOIN job ON job.id = job_item.job_id
                WHERE job.platform = ? AND job_item.status IN (?, ?)
                """, arguments: [
                    platform,
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ])
        }
    }

    /// Transition a job's lifecycle (7A) — e.g. `.complete` at the cursor
    /// terminator, `.paused` on a user pause, `.halted` on a fatal auth /
    /// rate-limit wall. Bumps `updatedAt`. `.notFound` if the job is absent.
    public func setJobStatus(jobID: UUID, to status: JobStatus) async throws {
        try await write { db in
            guard var job = try Job.fetchOne(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            job.status = status
            job.updatedAt = Date()
            try job.update(db)
        }
    }

    /// Pause every `open` sweep whose last activity (`updatedAt`) is older than
    /// `seconds` before `now`. A browser sweep whose tab/worker dies can no longer
    /// send its own close, so its job would otherwise linger forever as a phantom
    /// "running" entry; this reconciles it to `paused` (resumable). `seconds == 0`
    /// pauses ALL open jobs — used at launch, when no sweep can possibly be running.
    /// Staleness check and pause run in one write transaction (G9). `now` is
    /// injected for deterministic tests.
    @discardableResult
    public func pauseStaleOpenJobs(olderThan seconds: TimeInterval, now: Date) async throws -> [UUID] {
        let cutoff = now.addingTimeInterval(-seconds)
        // Single write transaction: filter + mutate together so a job touched in
        // the gap between a prior read and write is not wrongly paused (G9).
        return try await write { db in
            let stale = try Job
                .filter(Column("status") == JobStatus.open.rawValue)
                .filter(Column("updated_at") <= cutoff)
                .fetchAll(db)
            guard !stale.isEmpty else { return [] }
            var paused: [UUID] = []
            for var job in stale {
                job.status = .paused
                job.updatedAt = now
                try job.update(db)
                paused.append(job.id)
            }
            return paused
        }
    }

    /// Proactive GC of the `known ⟺ blob present` invariant. `deleteAssets` forgets a
    /// blob's ledger rows the instant it orphans, but an asset removed by any OTHER
    /// path (a delete predating the forget feature, a future non-`deleteAssets` caller)
    /// strands its `job_item` as stale-"known" — and a later sweep would then
    /// dedup-skip that source forever despite the bytes being gone, so it never
    /// re-imports. This sweeps every `job_item` whose blob has no backing asset,
    /// forgets it, and recomputes the affected jobs' counts. Check + delete run in
    /// ONE write transaction so a concurrent ingest can't be wrongly pruned (G9).
    /// Returns the job ids reconciled.
    @discardableResult
    public func reconcileOrphanedKnownItems() async throws -> [UUID] {
        try await write { db in
            let orphanedHashes = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_hash FROM job_item
                 WHERE blob_hash IS NOT NULL
                   AND NOT EXISTS (
                     SELECT 1 FROM asset WHERE asset.blob_hash = job_item.blob_hash)
                """)
            guard !orphanedHashes.isEmpty else { return [] }
            let touched = try Self.forgetOrphanedKnownItems(orphanedHashes, in: db)
            return touched.compactMap { UUID(uuidString: $0) }
        }
    }

    /// One job by id (progress UI). `.notFound` if absent. Read.
    public func getJob(id: UUID) async throws -> Job {
        try await read { db in
            guard let job = try Job.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "job", id: id)
            }
            return job
        }
    }

    /// A job's items, ordered by `source_id` (stable). `.notFound` if the job is
    /// absent. Read — for progress detail (skipped/failed/dedup breakdown).
    public func jobItems(forJob jobID: UUID) async throws -> [JobItem] {
        try await read { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return try JobItem
                .filter(Column("job_id") == Self.key(jobID))
                .order(Column("source_id"))
                .fetchAll(db)
        }
    }

    /// All jobs, newest first (the progress UI's list). Read.
    public func listJobs() async throws -> [Job] {
        try await read { db in
            try Job.order(Column("created_at").desc, Column("id")).fetchAll(db)
        }
    }

    /// A job's per-outcome item tally (the progress breakdown: ingested / deduped /
    /// skipped / retryable / permanent). Aggregated in SQL (a `GROUP BY`, not by
    /// loading every row) so a large sweep's progress reads stay cheap. A status
    /// with no items is absent from the map (callers default to 0). `.notFound` if
    /// the job is absent. Read.
    public func jobItemCounts(forJob jobID: UUID) async throws -> [JobItemStatus: Int] {
        try await read { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT status, count(*) AS n FROM job_item WHERE job_id = ? GROUP BY status
                """, arguments: [Self.key(jobID)])
            var counts: [JobItemStatus: Int] = [:]
            for row in rows {
                if let status = JobItemStatus(rawValue: row["status"]) {
                    counts[status] = row["n"]
                }
            }
            return counts
        }
    }

    /// A job's current lifecycle status (the relay feedback the extension polls per
    /// item to honour an app-side pause/cancel — 7A). `.notFound` if absent. Read.
    public func jobStatus(forJob jobID: UUID) async throws -> JobStatus {
        try await read { db in
            guard let raw = try String.fetchOne(
                db, sql: "SELECT status FROM job WHERE id = ?", arguments: [Self.key(jobID)]),
                let status = JobStatus(rawValue: raw) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return status
        }
    }

    // MARK: - Private query helpers

    /// Sanitize arbitrary user text into a safe FTS5 MATCH query. Each
    /// whitespace-separated term is wrapped as a quoted FTS5 string (doubling
    /// any embedded `"` per FTS5's escaping rule) and the quoted terms are joined
    /// with spaces (implicit AND). So `brass wood` → `"brass" "wood"` (both must
    /// match) and punctuation / stray quotes can never form malformed MATCH
    /// syntax (no syntax-error throw). Quoting also neutralizes the FTS5
    /// operators (`*`, `:`, `^`, `-`, `(`, `OR`, …) as literal text.
    ///
    /// Type-ahead PREFIX (044/045 · 5A/14A): the FINAL term is emitted as an FTS5
    /// prefix token (`"wo"*` matches "wood", "wool", …) so results appear as the
    /// user types a word — BUT only when
    ///   • the input has no trailing whitespace (a trailing space means the word
    ///     is finished, so match it exactly), AND
    ///   • that term is ≥2 characters (a 1-char prefix matches a huge slice of the
    ///     index for no useful precision, and inflates the query).
    /// Earlier terms always match exactly — only the word being typed is a prefix.
    /// The `*` sits OUTSIDE the closing quote (`"wo"*`), which is the FTS5
    /// quoted-prefix syntax; the quoting still neutralizes every operator inside.
    static func ftsMatchQuery(_ text: String) -> String {
        let terms = text.split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return "" }
        let starLast = !(text.last?.isWhitespace ?? true)
        let lastIndex = terms.count - 1
        return terms.enumerated().map { index, term in
            let quoted = "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            let isPrefix = index == lastIndex && starLast && term.count >= 2
            return isPrefix ? "\(quoted)*" : quoted
        }.joined(separator: " ")
    }

    /// Build a `trigram`-tokenizer MATCH query for SUBSTRING search (046 Phase 2),
    /// or `nil` when the text isn't trigram-eligible.
    ///
    /// The trigram tokenizer indexes 3-character windows, so a term needs ≥3
    /// characters to form any trigram. To keep the multi-term AND semantics of the
    /// unicode61 arms EXACT, the whole query is trigram-eligible only when EVERY
    /// term is ≥3 chars — otherwise this returns `nil` and the caller falls back to
    /// the unicode61 / LIKE path for the entire query (rather than silently
    /// dropping the short term and loosening the AND to a partial match).
    ///
    /// Each eligible term is wrapped as a quoted FTS5 phrase (doubling embedded `"`
    /// per FTS5's escaping rule, neutralizing every operator as literal text) and
    /// the phrases are AND-joined, so `brut concrete` → `"brut" AND "concrete"`
    /// (both substrings must appear). A single term → just its quoted phrase.
    /// Empty / all-short input → `nil`.
    static func trigramMatchQuery(_ text: String) -> String? {
        let terms = text.split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty, terms.allSatisfy({ $0.count >= 3 }) else { return nil }
        return terms.map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: " AND ")
    }

    /// Wrap a needle as a `LIKE ? ESCAPE '\'` CONTAINS pattern (`%needle%`) with
    /// its wildcards escaped (044/045 · 6A). Shared by every leading-wildcard arm
    /// — the free-text tag / collection-name OR arms and the `tag:` conjunct — so
    /// the escape (a miss here means a needle containing `%` matches everything)
    /// lives in ONE place. The caller supplies the SQL `LIKE ? ESCAPE '\'`.
    static func containsPattern(_ needle: String) -> String {
        "%" + escapeLikePrefix(needle) + "%"
    }

    /// Escape a user prefix for a `LIKE ? ESCAPE '\'` pattern so its `%`, `_`, and
    /// `\` are matched literally (the caller appends the trailing `%` wildcard).
    /// Without this, a tag prefix containing `%` would match everything.
    static func escapeLikePrefix(_ prefix: String) -> String {
        prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// The on-disk key form of a UUID (lowercased TEXT, C5) — what GRDB's
    /// key-based fetch and the column filters must bind to.
    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The (collection, asset) membership row, if any.
    private static func membership(
        _ db: Database, collectionID: UUID, assetID: UUID
    ) throws -> CollectionItem? {
        try CollectionItem
            .filter(Column("collection_id") == key(collectionID))
            .filter(Column("asset_id") == key(assetID))
            .fetchOne(db)
    }

    /// 18A dedup lookup: an existing asset sharing `blobHash` whose source
    /// matches the incoming provenance — same `original_url` when one is given,
    /// else same `platform` (the local-capture case where no URL exists). The
    /// shared blob hash means the bytes are identical; the source match means
    /// the provenance is identical, so reuse is safe.
    private static func findDuplicate(
        _ db: Database, blobHash: String, source: SourceDraft
    ) throws -> Asset? {
        // Candidate sources whose provenance matches the incoming draft.
        let matchingSources: QueryInterfaceRequest<Source>
        if let url = source.originalURL,
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matchingSources = Source.filter(Column("original_url") == url)
        } else {
            matchingSources = Source.filter(Column("platform") == source.platform.rawValue)
        }
        let sourceIDs = try String.fetchAll(
            db, matchingSources.select(Column("id")))
        guard !sourceIDs.isEmpty else { return nil }

        // The first asset sharing the blob hash AND one of those sources.
        return try Asset
            .filter(Column("blob_hash") == blobHash)
            .filter(sourceIDs.contains(Column("source_id")))
            .fetchOne(db)
    }

    /// Kind-aware dedup for a MEDIA-LESS asset (003 · O1): an existing asset with
    /// the same `(kind, dedup_key)` whose source matches the incoming provenance
    /// — same `original_url` when one is given, else same `platform` (the local-
    /// capture case). The blob-based ``findDuplicate`` doesn't apply (no bytes);
    /// the `dedup_key` (canonical hex / URL / tweet-id) is the identity instead.
    /// A `nil` key (nothing to match on) is always a miss.
    private static func findDuplicateContent(
        _ db: Database, kind: AssetKind, dedupKey: String?, source: SourceDraft
    ) throws -> Asset? {
        guard let dedupKey else { return nil }
        // Candidate sources whose provenance matches the incoming draft (mirrors
        // findDuplicate's source-match rule).
        let matchingSources: QueryInterfaceRequest<Source>
        if let url = source.originalURL,
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matchingSources = Source.filter(Column("original_url") == url)
        } else {
            matchingSources = Source.filter(Column("platform") == source.platform.rawValue)
        }
        let sourceIDs = try String.fetchAll(
            db, matchingSources.select(Column("id")))
        guard !sourceIDs.isEmpty else { return nil }

        // The first asset of this kind sharing the dedup key AND one of those
        // sources.
        return try Asset
            .filter(Column("kind") == kind.rawValue)
            .filter(Column("dedup_key") == dedupKey)
            .filter(sourceIDs.contains(Column("source_id")))
            .fetchOne(db)
    }
}
