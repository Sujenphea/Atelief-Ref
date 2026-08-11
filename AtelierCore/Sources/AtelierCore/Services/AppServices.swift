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

    /// The newest schema migration this build knows about — what any
    /// library it has opened is migrated to.
    ///
    /// Public so backup and archive manifests (008 · H5/H6) can record the
    /// schema their copy was written from, which is what lets a reader refuse a
    /// file from a FUTURE build instead of misreading it. A build-time constant
    /// rather than a query, because `LibraryDatabase.init` migrates to the
    /// latest on open: an `AppServices` that exists is an `AppServices` whose
    /// database is at this version.
    public static var schemaVersion: String {
        Migrator.registeredIdentifiers.last ?? ""
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

    // MARK: - Color buckets (085 · C1)

    /// How much of an image a color must cover before the filter calls the image
    /// that color.
    ///
    /// Applied at QUERY time, not at write time — every bucket is stored, so this
    /// can be re-judged without re-deriving a single row. 0.15 keeps a wall or a
    /// backdrop qualifying while a 3% accent does not; an image where a color is
    /// merely *present* is not an image a search for that color wants back.
    public static let defaultColorCoverageFloor = 0.15

    /// Replace `assetID`'s palette-bucket rows wholesale.
    ///
    /// `buckets` maps a bucket's raw value to the share of the image it covers.
    /// **A dictionary rather than a list, deliberately**: the table's primary key
    /// is `(asset_id, bucket)` because same-bucket swatches are merged upstream,
    /// and a dictionary makes "one entry per bucket" impossible to violate at the
    /// call site rather than a constraint violation at the write.
    ///
    /// Delete-then-insert in ONE transaction, so a re-derivation never leaves an
    /// asset briefly colorless and a bucket it no longer has cannot survive.
    /// Passing an empty dictionary clears the asset's rows, which is what an
    /// extraction that produced nothing means.
    ///
    /// The bucket values are opaque here — see ``AssetColor``.
    /// `paletteVersion` is STAMPED on the asset's analysis row, and it is what
    /// takes the asset out of ``assetIDsNeedingColorBuckets(paletteVersion:limit:)``.
    /// Row count cannot do that job: an unreadable palette derives zero rows,
    /// which is indistinguishable from "not derived yet", so such an asset would
    /// be handed back on every pass forever.
    public func replaceColors(
        assetID: UUID, buckets: [Int: Double], paletteVersion: Int
    ) async throws {
        try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            try db.execute(
                sql: "DELETE FROM asset_color WHERE asset_id = ?",
                arguments: [Self.key(assetID)])
            // Sorted so the write order is deterministic — it makes a failing
            // test's diff readable and costs nothing at five rows.
            for (bucket, coverage) in buckets.sorted(by: { $0.key < $1.key }) {
                try AssetColor(assetID: assetID, bucket: bucket, coverage: coverage)
                    .insert(db)
            }
            // No-op when the asset has never been analyzed — the rows are still
            // written, so a caller that derives buckets by another route is not
            // silently dropped.
            try db.execute(sql: """
                UPDATE asset_analysis SET colors_palette_version = ?
                WHERE asset_id = ?
                """, arguments: [paletteVersion, Self.key(assetID)])
        }
    }

    /// `assetID`'s palette buckets, most-covering first.
    ///
    /// Ties break on the bucket's raw value so the order is total — the detail
    /// page's swatch row must not reshuffle between reads of unchanged data.
    public func colors(for assetID: UUID) async throws -> [AssetColor] {
        try await read { db in
            try AssetColor
                .filter(Column("asset_id") == Self.key(assetID))
                .order(Column("coverage").desc, Column("bucket").asc)
                .fetchAll(db)
        }
    }

    /// The next batch of asset ids whose colors have been extracted but not yet
    /// filed into buckets — the resumable derivation pass (085 · C1).
    ///
    /// "Has `colors`, and has not been filed at this palette version" is the
    /// entire state, so it is one WHERE clause and needs no ledger. The work is
    /// pure string→bucket arithmetic over data already on disk: **no blob is read
    /// and no image is decoded**, which is why this is its own pass rather than
    /// an `analyzer_version` bump that would re-decode the whole library.
    ///
    /// The comparison is `<`, not `IS NULL`, so bumping the palette — a new
    /// bucket, a widened threshold — re-queues every asset without a migration,
    /// exactly as `analyzer_version` does for the analyzer.
    ///
    /// Newest-first, capped at `limit` (clamped to `1...1000`), matching
    /// ``assetIDsNeedingAnalysis(analyzerVersion:limit:)``.
    public func assetIDsNeedingColorBuckets(
        paletteVersion: Int, limit: Int = 200
    ) async throws -> [UUID] {
        let clamped = min(max(limit, 1), 1000)
        return try await read { db in
            try UUID.fetchAll(db, sql: """
                SELECT an.asset_id
                FROM asset_analysis an
                JOIN asset a ON a.id = an.asset_id
                WHERE an.colors IS NOT NULL
                  AND (an.colors_palette_version IS NULL
                       OR an.colors_palette_version < ?)
                ORDER BY a.created_at DESC, a.id DESC
                LIMIT ?
                """, arguments: [paletteVersion, clamped])
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

    /// Every LIVE analyzed image's perceptual signature — the whole input to the
    /// near-duplicate review surface (012 · I5).
    ///
    /// A read, and only a read: Core groups nothing and proposes nothing. The
    /// clustering that turns these into review groups is a pure function in
    /// AtelierIngestion (the 2A boundary — imaging concepts never enter Core), and
    /// the surface it feeds never merges or deletes on its own.
    ///
    /// The whole library in one query, like ``blobUsage()`` and
    /// ``referencedBlobs()`` — "which images are near-duplicates of each other" is
    /// not a question a page of the library can answer, and a paged version would
    /// silently hide clusters that straddle a page boundary. Two columns per row
    /// keeps that affordable.
    ///
    /// The JOIN back to `asset` is what makes the result LIVE. `asset_analysis`
    /// cascades on delete so a removed asset's row is already gone, but the join
    /// also drops rows whose asset lost its bytes, is not a downloaded image, or
    /// was never byte-backed to begin with — so the surface can never propose an
    /// action on something that isn't there. Rows with a `NULL` phash (analyzed
    /// for OCR / colour before hashing succeeded) are skipped rather than treated
    /// as zero, which would collide them all into one false cluster.
    ///
    /// Ordered oldest-first (`created_at`, then `id` to break ties), because that
    /// order is preserved inside every cluster: the copy the user has had longest
    /// heads the group and reads as the original.
    public func perceptualHashes() async throws -> [AssetPerceptualHash] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT an.asset_id AS asset_id, an.phash AS phash
                FROM asset_analysis an
                JOIN asset a ON a.id = an.asset_id
                WHERE an.phash IS NOT NULL
                  AND a.kind = ?
                  AND a.blob_hash IS NOT NULL
                  AND a.download_state = ?
                ORDER BY a.created_at ASC, a.id ASC
                """, arguments: [
                    AssetKind.image.rawValue,
                    DownloadState.downloaded.rawValue,
                ]).compactMap { row -> AssetPerceptualHash? in
                    guard let key = row["asset_id"] as String?,
                          let id = UUID(uuidString: key),
                          let phash = row["phash"] as Int64?
                    else { return nil }
                    return AssetPerceptualHash(assetID: id, phash: phash)
                }
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
        favoritesOnly: Bool = false,
        colorBuckets: [Int] = [],
        colorMatch: TagMatch = .any,
        minimumColorCoverage: Double = AppServices.defaultColorCoverageFloor,
        limit: Int = 50
    ) async throws -> [AssetDetail] {
        guard !queryVector.isEmpty else { return [] }
        let clampedLimit = min(max(limit, 1), 500)
        let distinctTagIDs = Array(Set(tagIDs))
        let distinctCollectionIDs = Array(Set(collectionIDs))
        let distinctColorBuckets = Array(Set(colorBuckets)).sorted()

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
            // The favorites chip narrows BOTH search modes (011 · U5). Without it
            // here, flipping keyword → meaning would silently drop the filter the
            // user can still see selected in the field.
            if favoritesOnly {
                conditions.append("a.is_favorite = 1")
            }
            // The color chips (085 · C2), for exactly that reason: a color token
            // the user can still see in the field must not stop filtering because
            // they switched to meaning mode. Same EXISTS shape and same `.any` /
            // `.all` split as `searchAssets` — see the long note there.
            if !distinctColorBuckets.isEmpty {
                switch colorMatch {
                case .any:
                    let placeholders = databaseQuestionMarks(count: distinctColorBuckets.count)
                    conditions.append("""
                        EXISTS (SELECT 1 FROM asset_color c
                                WHERE c.asset_id = a.id
                                  AND c.bucket IN (\(placeholders))
                                  AND c.coverage >= ?)
                        """)
                    args.append(contentsOf: distinctColorBuckets.map { $0 as DatabaseValueConvertible })
                    args.append(minimumColorCoverage)
                case .all:
                    for bucket in distinctColorBuckets {
                        conditions.append("""
                            EXISTS (SELECT 1 FROM asset_color c
                                    WHERE c.asset_id = a.id
                                      AND c.bucket = ?
                                      AND c.coverage >= ?)
                            """)
                        args.append(bucket)
                        args.append(minimumColorCoverage)
                    }
                }
            }
            // The archive shelf (023 · A), for the same reason the favorites chip
            // is here: flipping keyword → meaning must not resurrect items the
            // keyword search hides. A candidate-stage conjunct, so archived rows
            // never reach the scorer — the vector maths below is per-candidate,
            // which makes filtering here strictly cheaper than filtering after.
            conditions.append("a.archived_at IS NULL")
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
            //    via addAssets, not a side effect of re-ingest), honoring the
            //    Unsorted invariant on the 18A dedup path — a re-capture of bytes
            //    already in the library must not land the asset in two homes.
            try Self.placeIngested(
                db, assetID: resolvedAsset.id, in: collectionID, placement: placement)

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

            // 4. ensure ONE membership (idempotent on membership — matches ingest,
            //    Unsorted invariant included).
            try Self.placeIngested(
                db, assetID: resolvedAsset.id, in: collectionID, placement: placement)

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
    ///
    /// Enforces the Unsorted invariant (F3 · "Unsorted means NOT filed"):
    /// - Into a REAL collection, the batch's Unsorted memberships are dropped in
    ///   the same transaction — a filed asset is no longer unsorted, so it stops
    ///   surfacing in both places at once.
    /// - Into Unsorted itself, an asset that already belongs to a real collection
    ///   is SKIPPED. Un-triage is only meaningful for an asset with nowhere else
    ///   to live; filing something into Unsorted alongside its real folders is
    ///   exactly the state this invariant exists to prevent.
    ///
    /// **Returns the assets this add EVICTED from Unsorted** — empty for every add
    /// that did not (into Unsorted itself, or a batch that was already filed). The
    /// first rule above means an "add" is also a removal for exactly one collection,
    /// so a caller watching Unsorted cannot tell from the verb alone whether the
    /// asset just left the feed in front of it (356). Reporting it here keeps that
    /// rule stated once, where it runs, instead of mirrored by every client that
    /// needs to know. `@discardableResult` — most callers legitimately don't care.
    @discardableResult
    public func addAssets(_ assetIDs: [UUID], to collectionID: UUID) async throws -> [UUID] {
        try await write { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            let intoUnsorted = collectionID == Collection.unsortedID
            let now = Date()
            // Append the batch after any existing items, in the given order — each
            // newly-inserted membership takes the next manual slot (skipped assets
            // that are already members don't consume one).
            var order = try Self.nextManualOrder(db, collectionID: collectionID)
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                if intoUnsorted, try Self.isFiled(db, assetID: assetID) { continue }
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
            guard !intoUnsorted else { return [] }
            return try Self.evictFromUnsorted(db, assetIDs: assetIDs)
        }
    }

    /// Bulk-remove memberships, IN ONE transaction (P15). Idempotent — removing
    /// a non-member is a no-op.
    ///
    /// Never orphans (F3): an asset left with NO memberships falls back to the
    /// Unsorted home, so "remove from this folder" always leaves it reachable
    /// somewhere. Removing from Unsorted ITSELF is exempt — otherwise the verb
    /// would re-add what it just removed and the Unsorted grid could never be
    /// cleared (Delete is the verb for leaving the library).
    public func removeAssets(_ assetIDs: [UUID], from collectionID: UUID) async throws {
        try await write { db in
            for assetID in assetIDs {
                try CollectionItem
                    .filter(Column("collection_id") == Self.key(collectionID))
                    .filter(Column("asset_id") == Self.key(assetID))
                    .deleteAll(db)
            }
            if collectionID != Collection.unsortedID {
                try Self.rehomeUnfiled(db, assetIDs: assetIDs)
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
    ///
    /// The Unsorted invariant rides along, exactly as in ``addAssets(_:to:)``: a
    /// move into a real collection also drops the batch's Unsorted memberships,
    /// and a move into Unsorted skips the insert for an asset that still belongs
    /// to a real collection OTHER than the source — it leaves the source, but it
    /// is not unsorted, so it never lands in both. Such an asset therefore keeps
    /// at least one membership, which is why no orphan fallback is needed here.
    public func moveAssets(_ assetIDs: [UUID], from sourceID: UUID, to targetID: UUID) async throws {
        guard sourceID != targetID, !assetIDs.isEmpty else { return }
        try await write { db in
            guard try Collection.exists(db, key: Self.key(sourceID)) else {
                throw AtelierError.notFound(entity: "collection", id: sourceID)
            }
            guard try Collection.exists(db, key: Self.key(targetID)) else {
                throw AtelierError.notFound(entity: "collection", id: targetID)
            }
            let intoUnsorted = targetID == Collection.unsortedID
            let now = Date()
            var nextOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(manual_order), -1) + 1 FROM collection_item
                WHERE collection_id = ?
                """, arguments: [Self.key(targetID)]) ?? 0
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                // Filed elsewhere → un-triaging into Unsorted is meaningless; the
                // asset just leaves the source. `excluding: sourceID` because that
                // membership is about to go.
                let staysFiled = try intoUnsorted
                    && Self.isFiled(db, assetID: assetID, excluding: sourceID)
                let isMember = try Self.membership(
                    db, collectionID: targetID, assetID: assetID) != nil
                if !isMember, !staysFiled {
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
            if !intoUnsorted {
                try Self.evictFromUnsorted(db, assetIDs: assetIDs)
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
    /// Returns the reclaimable blobs as ``BlobRef`` so the caller (which
    /// owns the `MediaStore`) can trash the on-disk blob + thumbnail files; Core
    /// itself never touches the filesystem. Tag rows survive (only the
    /// `asset_tag` join cascades), matching ``removeTag(_:from:source:)``.
    @discardableResult
    public func deleteAssets(_ assetIDs: [UUID]) async throws -> [BlobRef] {
        try await write { db in try Self.performDelete(assetIDs, in: db) }
    }

    /// The delete cascade, shared by ``deleteAssets(_:)`` and the recoverable
    /// variant so both run the SAME transaction logic (010 · delete-undo).
    private static func performDelete(_ assetIDs: [UUID], in db: Database) throws -> [BlobRef] {
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
        var orphans: [BlobRef] = []
        for hash in orderedHashes {
            let stillReferenced = try Asset
                .filter(Column("blob_hash") == hash)
                .fetchCount(db) > 0
            if !stillReferenced {
                orphans.append(BlobRef(blobHash: hash, mimeType: mimeByHash[hash]!))
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
    ///
    /// Hashes only. When the caller also needs each blob's FILE (to copy it, or
    /// to name it on disk), use ``referencedBlobs()`` instead — deriving the
    /// stored extension needs the mime type.
    public func referencedBlobHashes() async throws -> Set<String> {
        try await read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT DISTINCT blob_hash FROM asset WHERE blob_hash IS NOT NULL"))
        }
    }

    /// Every blob an asset currently references, as ``BlobRef`` — the read half
    /// of the file-level operations Core can't perform itself (008 H5's backup
    /// copy set). The symmetric counterpart of ``deleteAssets(_:)``'s return:
    /// same descriptor, opposite guarantee (these are LIVE, never reap them).
    ///
    /// Exactly one row per distinct hash. Two nuances the SQL settles
    /// deliberately rather than leaving to chance:
    /// - `mime_type` is nullable; a NULL yields `""`, which
    ///   `ImageMetadata.fileExtension(forMIMEType:)` also yields for anything it
    ///   can't resolve, and which `MediaStore` stores as a dotless path. So the
    ///   empty string round-trips correctly instead of needing a special case.
    /// - Content-identical assets normally share a mime, but nothing enforces
    ///   it. `MIN` picks one **deterministically** so a backup diff is
    ///   reproducible run-to-run; a caller that finds no file at the derived
    ///   extension must treat it as a miss to report, not a crash — the bytes on
    ///   disk carry whichever extension ingest wrote first.
    public func referencedBlobs() async throws -> [BlobRef] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT blob_hash, COALESCE(MIN(mime_type), '') AS mime_type
                FROM asset
                WHERE blob_hash IS NOT NULL
                GROUP BY blob_hash
                ORDER BY blob_hash
                """)
                .map { BlobRef(blobHash: $0["blob_hash"], mimeType: $0["mime_type"]) }
        }
    }

    // MARK: - Library stats (016 · A)
    //
    // Three READS, and deliberately nothing else. The storage surface is a pure
    // read layer over data that already exists — these aggregate in SQL (a
    // `GROUP BY`, never a fetch-all-then-count in Swift) so a hundred-thousand
    // item library answers "how many videos?" without loading a hundred thousand
    // rows. On-disk SIZES are not here and never will be: Core cannot touch
    // files (A2), so the size half arrives from `LibraryStorageScanner` and is
    // joined against ``blobUsage()`` a layer up.

    /// How many assets of each ``AssetKind`` the library holds.
    ///
    /// A kind with no assets is ABSENT from the map rather than present as `0`
    /// — callers default, and the UI decides whether an empty kind is worth a
    /// row. A stored rawValue this build doesn't know (a library written by a
    /// newer version) is skipped rather than crashing the whole count: a missing
    /// row is a small lie, a failed stats pane is a big one.
    public func assetCountsByKind() async throws -> [AssetKind: Int] {
        try await read { db in
            var counts: [AssetKind: Int] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT kind, count(*) AS n FROM asset GROUP BY kind") {
                guard let kind = AssetKind(rawValue: row["kind"]) else { continue }
                counts[kind] = row["n"]
            }
            return counts
        }
    }

    /// How many assets came from each ``Platform``, via each asset's required
    /// ``Source``. Same absent-means-zero and skip-the-unknown contract as
    /// ``assetCountsByKind()``.
    ///
    /// Counted per ASSET, not per source: one Instagram carousel is one source
    /// and ten images, and "10 from Instagram" is what the user has.
    public func assetCountsByPlatform() async throws -> [Platform: Int] {
        try await read { db in
            var counts: [Platform: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT s.platform AS platform, count(*) AS n
                FROM asset a JOIN source s ON s.id = a.source_id
                GROUP BY s.platform
                """) {
                guard let platform = Platform(rawValue: row["platform"]) else { continue }
                counts[platform] = row["n"]
            }
            return counts
        }
    }

    /// Every distinct blob with the assets that reference it — the DB half of the
    /// largest-items list (the byte sizes come from the filesystem scan).
    ///
    /// One row per hash, like ``referencedBlobs()``, and for the same reason: the
    /// list ranks FILES. `MIN` picks the kind / platform / label deterministically
    /// so two runs over an unchanged library produce byte-identical ordering —
    /// content-identical assets normally agree on all three, but nothing enforces
    /// it, and a top-N list that reshuffles on refresh reads as a bug.
    ///
    /// `group_concat` gathers the asset ids in one pass rather than a query per
    /// row (N+1 over the whole library, to build a list of ten). SQLite does not
    /// define the order WITHIN a group, so the ids are sorted here.
    public func blobUsage() async throws -> [BlobUsage] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.blob_hash AS blob_hash,
                       COALESCE(MIN(a.mime_type), '') AS mime_type,
                       MIN(a.kind) AS kind,
                       MIN(s.platform) AS platform,
                       MIN(COALESCE(a.name, s.title)) AS display_name,
                       group_concat(a.id) AS asset_ids
                FROM asset a JOIN source s ON s.id = a.source_id
                WHERE a.blob_hash IS NOT NULL
                GROUP BY a.blob_hash
                ORDER BY a.blob_hash
                """).compactMap { row -> BlobUsage? in
                    // An unknown kind/platform rawValue drops the ROW, not the
                    // pane — the same forward-compatibility stance as the counts.
                    guard let kind = AssetKind(rawValue: row["kind"]),
                          let platform = Platform(rawValue: row["platform"]) else { return nil }
                    let ids: [UUID] = (row["asset_ids"] as String? ?? "")
                        .split(separator: ",")
                        .compactMap { UUID(uuidString: String($0)) }
                        .sorted { $0.uuidString < $1.uuidString }
                    let name: String? = row["display_name"]
                    return BlobUsage(
                        blobHash: row["blob_hash"], mimeType: row["mime_type"],
                        kind: kind, platform: platform,
                        displayName: name?.isEmpty == true ? nil : name,
                        assetIDs: ids)
                }
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
    ///
    /// `includeArchived` (023 · A) is deliberately **NOT defaulted**, and this is
    /// the one funnel where that earns its keep, because it has callers on both
    /// sides. Browsing passes `false` — an archived asset keeps its membership
    /// row and is hidden at the READ, which is what lets unarchiving put it back
    /// exactly where it was. The backup writer passes `true`: it walks the
    /// library one collection at a time through this same read, and a default
    /// here would mean every backup silently omitted the user's whole shelf and
    /// every restore lost it — a data-loss bug with no symptom until far too
    /// late. A non-defaulted parameter turns that into a compile error instead.
    public func collectionItems(
        in collectionID: UUID, sort: SortMode = .manual, includeArchived: Bool
    ) async throws -> [CollectionItemDetail] {
        try await read { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            // CollectionItem ⋈ Asset ⋈ Source, all required (P14): one round-trip,
            // no N+1. GRDB qualifies bare base columns to `collection_item`, so
            // the asset-keyed orderings reference the joined `asset` table by
            // name to avoid picking the membership row's columns.
            var assetJoin = CollectionItem.asset.including(required: Asset.source)
            if !includeArchived {
                // On the JOIN rather than as a trailing WHERE: this is a required
                // (INNER) join, so the two are equivalent to SQLite, and putting
                // it here keeps the predicate next to the table it is about.
                assetJoin = assetJoin.filter(Column("archived_at") == nil)
            }
            var request = CollectionItem
                .filter(Column("collection_id") == Self.key(collectionID))
                .including(required: assetJoin)
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

    /// The archive shelf itself (023 · A) — every archived asset with its
    /// provenance, most recently archived first.
    ///
    /// Its own function rather than a flag on a browse read, because it is not a
    /// collection and shares nothing with one: no membership rows, no manual
    /// order, no sort modes, and no scope. It is the whole library filtered to
    /// `archived_at IS NOT NULL`, which is exactly the query the v20 partial
    /// index exists to serve.
    ///
    /// **Returns the full array, no cursor** — a deliberate v1 choice, not an
    /// oversight. `collectionItems` justifies the same shape by being
    /// collection-scoped (P16), and that justification does NOT carry over to a
    /// library-wide read, so this one is measured instead: `ScaleHarnessTests`
    /// times a seeded shelf, and paging lands if and when that says it must.
    /// `archived_at DESC, id DESC` — the id tie-break keeps a batch archived in
    /// one gesture (one `UPDATE`, one timestamp) in a deterministic order.
    public func shelfAssets() async throws -> [AssetDetail] {
        try await read { db in
            let request = Asset
                .filter(sql: "asset.archived_at IS NOT NULL")
                .including(required: Asset.source)
                .order(sql: "asset.archived_at DESC, asset.id DESC")
            return try AssetSourceRow.fetchAll(db, request).map {
                AssetDetail(asset: $0.asset, source: $0.source)
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
        guard !ids.isEmpty else { return [:] }
        return try await read { db in
            try Self.covers(in: db, table: "collection", ids: ids)
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

            let (counts, hashes) = try Self.stackPreviews(
                in: db, parentIDs: roots.map(\.id),
                childTable: "collection_item", parentColumn: "collection_id",
                recencyColumn: "added_at", limit: limit)

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

    /// Remember where a space was last looked at (018 · Cluster C). Stores the
    /// ``SpaceCamera`` as JSON TEXT in `space.camera`, mirroring
    /// ``updateSpaceItemStyle(itemID:style:)``'s opaque-TEXT write; `nil` clears the
    /// column back to "never opened", which restores as fit-to-content.
    ///
    /// Two deliberate differences from every other space write, and both are the
    /// point rather than an oversight:
    ///
    /// - **It does NOT bump `updatedAt`.** A camera is view state, not content.
    ///   Panning a board is not editing it, and letting a pan touch `updatedAt`
    ///   would make merely *looking* at a board register as a change.
    /// - **It is idempotent, not `.notFound`.** The flush on close (018 · C3) can
    ///   land after the board was deleted, and a camera for a space that no longer
    ///   exists is nothing to raise at the user — the same reasoning as
    ///   ``removeSpaceItem(itemID:)``.
    public func setSpaceCamera(spaceID: UUID, camera: SpaceCamera?) async throws {
        let json = camera?.jsonString()
        try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(spaceID)) else { return }
            space.camera = json
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
        guard !ids.isEmpty else { return [:] }
        return try await read { db in
            try Self.covers(in: db, table: "space", ids: ids)
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

            let (counts, hashes) = try Self.stackPreviews(
                in: db, parentIDs: spaces.map(\.id),
                childTable: "space_item", parentColumn: "space_id",
                recencyColumn: "created_at", limit: limit)

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

    /// Add MANY asset references to a space in ONE transaction (059 · SP2 / 13A) —
    /// the insert analog of ``setSpaceItemPlacements(_:)``. A drag / import of N
    /// references mints N `space_item` rows in a single atomic write instead of N
    /// round-trips through the serialized writer. The space is validated ONCE; every
    /// asset must exist (`.notFound`) and every placement is validated up front, so
    /// an unknown asset or bad rect rolls the WHOLE batch back (all-or-nothing,
    /// matching the single-item contract). An empty batch is a no-op returning `[]`.
    /// The same asset MAY appear twice (each row has its own id) — a deliberate
    /// caller act, mirroring ``addAssetToSpace``.
    @discardableResult
    public func addAssetsToSpace(
        _ placements: [SpaceAssetPlacement], to spaceID: UUID
    ) async throws -> [SpaceItem] {
        guard !placements.isEmpty else { return [] }
        for p in placements {
            try Validation.spaceItem(kind: .asset, assetID: p.assetID)
            try Validation.canvasPlacement(x: p.x, y: p.y, w: p.w, h: p.h)
        }
        let now = Date()
        let items = placements.map { p in
            SpaceItem(
                id: UUID(), spaceID: spaceID, kind: .asset, assetID: p.assetID,
                x: p.x, y: p.y, w: p.w, h: p.h, z: p.z, style: nil,
                createdAt: now, updatedAt: now)
        }
        return try await write { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            for item in items {
                guard let assetID = item.assetID,
                      try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: item.assetID ?? item.id)
                }
                try item.insert(db)
            }
            return items
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
        // Delegate to the batch write so the single- and multi-tile paths can never
        // diverge on validation / update semantics (049 · D13, DRY).
        try await setSpaceItemPlacements(
            [SpaceItemPlacement(itemID: itemID, x: x, y: y, w: w, h: h, z: z)])
    }

    /// Persist MANY tile placements in ONE transaction (049 · D13) — a multi-select
    /// drag (and its undo/redo) moves N tiles as a single atomic write, not N
    /// round-trips through the serialized queue. Every placement is validated up
    /// front; an unknown id throws `.notFound` and rolls the WHOLE batch back
    /// (all-or-nothing, matching the single-item contract). An empty batch is a
    /// no-op.
    public func setSpaceItemPlacements(_ placements: [SpaceItemPlacement]) async throws {
        guard !placements.isEmpty else { return }
        for p in placements {
            try Validation.canvasPlacement(x: p.x, y: p.y, w: p.w, h: p.h)
        }
        try await write { db in
            let now = Date()
            for p in placements {
                guard var item = try SpaceItem.fetchOne(db, key: Self.key(p.itemID)) else {
                    throw AtelierError.notFound(entity: "space_item", id: p.itemID)
                }
                item.x = p.x; item.y = p.y; item.w = p.w; item.h = p.h; item.z = p.z
                item.updatedAt = now
                try item.update(db)
            }
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

    /// Restyle a freeform element AND (optionally) move/resize it in ONE
    /// transaction (054 §4.3 · R6 · D5 — 2C). An auto-sized text element's derived
    /// `w`/`h` is *part of* its style change, so the style write and the geometry
    /// write must never half-persist: a single `db.write {}` registers as one undo
    /// step and one atomic edit. `placement == nil` writes style only (the common
    /// `.fixed` path adds zero geometry writes). `.notFound` if the row is absent;
    /// the placement (when present) is validated (C8). Bumps `updatedAt`.
    public func updateSpaceItemStyleAndPlacement(
        itemID: UUID, style: ElementStyle?, placement: SpaceItemPlacement?
    ) async throws {
        if let placement {
            try Validation.canvasPlacement(x: placement.x, y: placement.y, w: placement.w, h: placement.h)
        }
        try await write { db in
            guard var item = try SpaceItem.fetchOne(db, key: Self.key(itemID)) else {
                throw AtelierError.notFound(entity: "space_item", id: itemID)
            }
            item.style = style?.jsonString()
            if let placement {
                item.x = placement.x; item.y = placement.y
                item.w = placement.w; item.h = placement.h; item.z = placement.z
            }
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
    /// - `favoritesOnly`: the favorites filter (011 · U5). `true` adds a plain AND
    ///   conjunct (`asset.is_favorite = 1`), so it composes with FTS text, tags,
    ///   platform and collection scope rather than replacing any of them; `false`
    ///   (the default) adds nothing. There is deliberately no "unfavorited only"
    ///   value — the chip is a two-state narrowing filter, not a tri-state.
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
        favoritesOnly: Bool = false,
        colorBuckets: [Int] = [],
        colorMatch: TagMatch = .any,
        minimumColorCoverage: Double = AppServices.defaultColorCoverageFloor,
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
        // Sorted as well as de-duplicated: the bucket list becomes SQL argument
        // order, and two calls asking for the same colors must build the same
        // statement so SQLite's prepared-statement cache sees one query rather
        // than one per permutation the caller happened to assemble.
        let distinctColorBuckets = Array(Set(colorBuckets)).sorted()
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

            // Favorites filter (011 · U5). A plain conjunct, so it AND-combines
            // with FTS text, the tag filters, the platform join and the
            // collection scope — the chip narrows whatever query is already
            // running rather than becoming a mode of its own. Qualified
            // `asset.is_favorite`: the source join makes a bare column ambiguous.
            if favoritesOnly {
                request = request.filter(sql: "asset.is_favorite = 1")
            }

            // The archive shelf (023 · A). Search NEVER returns archived items,
            // so this takes no parameter: there is no caller that wants them,
            // and a knob whose `true` branch is unreachable is noise on every
            // call site rather than an explicit choice. What guards a NEW read
            // against forgetting the predicate is the source-scan allowlist
            // test, not a parameter this funnel would have to be handed.
            //
            // A WHERE CONJUNCT, never a post-filter over the returned page, and
            // the second reason is the serious one: archived rows never reach
            // the per-row correlated scorer in `ordered(_:by:…)` (a speedup),
            // and a post-filter would silently SHORTEN pages — a page of 50
            // that loses 7 archived rows hands back 43, and the keyset cursor
            // would then page through gaps. Qualified `asset.archived_at`: the
            // source join makes a bare column ambiguous.
            request = request.filter(sql: "asset.archived_at IS NULL")

            // Color filter (085 · C1). One EXISTS per requested bucket, so the
            // rows never multiply the result the way a JOIN would — an asset
            // holding two of the chosen colors must appear once, not twice, and
            // `.all` needs each bucket checked independently anyway.
            //
            // `.any` (the default) is a single EXISTS over `bucket IN (…)`;
            // `.all` is one EXISTS per bucket, AND-combined. Same vocabulary as
            // `tagMatch`, deliberately — a second word for "match every one of
            // these" would be a second thing to learn.
            //
            // The coverage floor is applied HERE rather than at write time: every
            // bucket is stored, and what counts as "this image is red" is a
            // query-time judgement that can change without a re-derivation.
            if !distinctColorBuckets.isEmpty {
                switch colorMatch {
                case .any:
                    let placeholders = databaseQuestionMarks(count: distinctColorBuckets.count)
                    request = request.filter(sql: """
                        EXISTS (SELECT 1 FROM asset_color c
                                WHERE c.asset_id = asset.id
                                  AND c.bucket IN (\(placeholders))
                                  AND c.coverage >= ?)
                        """, arguments: StatementArguments(
                            distinctColorBuckets.map { $0 as DatabaseValueConvertible }
                                + [minimumColorCoverage]))
                case .all:
                    for bucket in distinctColorBuckets {
                        request = request.filter(sql: """
                            EXISTS (SELECT 1 FROM asset_color c
                                    WHERE c.asset_id = asset.id
                                      AND c.bucket = ?
                                      AND c.coverage >= ?)
                            """, arguments: [bucket, minimumColorCoverage])
                    }
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

    // MARK: - Favorites (011 · U5)

    /// Set (or clear) the favorite flag on `assetIDs`, in ONE transaction.
    ///
    /// **Idempotent by construction.** The `UPDATE` is filtered to the rows that
    /// are not already at `isFavorite`, so favoriting a favorite writes nothing —
    /// no row version churn, no `updated_at` on the collections that hold it, and
    /// the returned count is the number of rows that actually CHANGED. Callers
    /// (the undo registration in the shell) use that count to decide whether the
    /// action is worth an undo entry at all.
    ///
    /// A missing id is silently ignored rather than a `.notFound`: the caller is a
    /// multi-select over a grid that can be reloaded underneath it, and failing the
    /// whole batch because one tile was deleted a moment ago would be worse than
    /// starring the rest. (`setName` / `setNote` are single-asset editors and do
    /// throw — the distinction is deliberate.) An empty set is a no-op.
    @discardableResult
    public func setFavorite(_ isFavorite: Bool, for assetIDs: [UUID]) async throws -> Int {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return 0 }
        return try await write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            var args: [(any DatabaseValueConvertible)?] = [isFavorite]
            args.append(contentsOf: keys.map { $0 as (any DatabaseValueConvertible)? })
            args.append(isFavorite)
            try db.execute(sql: """
                UPDATE asset SET is_favorite = ?
                WHERE id IN (\(placeholders)) AND is_favorite <> ?
                """, arguments: StatementArguments(args))
            return db.changesCount
        }
    }

    /// Single-asset convenience over ``setFavorite(_:for:)`` — `true` when the row
    /// actually changed.
    @discardableResult
    public func setFavorite(_ isFavorite: Bool, for assetID: UUID) async throws -> Bool {
        try await setFavorite(isFavorite, for: [assetID]) > 0
    }

    /// The ids among `assetIDs` that are currently favorited. The read half of the
    /// ⌘D rule: the shell asks this to decide which way a MIXED selection flips,
    /// and to build the exact inverse an undo has to restore.
    public func favoritedAssetIDs(among assetIDs: [UUID]) async throws -> Set<UUID> {
        let ids = Array(Set(assetIDs))
        guard !ids.isEmpty else { return [] }
        let keys = ids.map(Self.key)
        return try await read { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            let found = try String.fetchAll(db, sql: """
                SELECT id FROM asset WHERE id IN (\(placeholders)) AND is_favorite = 1
                """, arguments: StatementArguments(keys))
            return Set(found.compactMap(UUID.init(uuidString:)))
        }
    }

    // MARK: - Shelf (023 · A — archive / unarchive)

    /// Put `assetIDs` on the archive shelf, in ONE transaction. Returns the
    /// number of rows that actually changed.
    ///
    /// Archiving touches ONE column. It does not remove a membership, move a
    /// space placement, drop a tag or reap a blob — that is the entire
    /// difference between this and a delete, and it is why unarchiving can put
    /// the item back exactly where it was without having to remember anything.
    ///
    /// **Idempotent, and re-archiving keeps the ORIGINAL timestamp.** The
    /// `UPDATE` is filtered to `archived_at IS NULL`, so archiving an already
    /// archived asset writes nothing rather than bumping it to the top of the
    /// shelf. A batch that mixes archived and un-archived assets therefore
    /// archives only the un-archived ones and leaves the rest where they sit,
    /// which is what the shelf's "most recently archived first" order means.
    ///
    /// The timestamp is server-authoritative (the service stamps `Date()`, like
    /// every other `*_at` in this layer). A missing id is silently ignored, for
    /// the same reason ``setFavorite(_:for:)`` ignores one: the caller is a
    /// multi-select over a grid that can be reloaded underneath it, and failing
    /// the whole batch because one tile was deleted a moment ago is worse than
    /// archiving the rest. An empty set is a no-op.
    @discardableResult
    public func archive(_ assetIDs: [UUID]) async throws -> Int {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return 0 }
        return try await write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            var args: [(any DatabaseValueConvertible)?] = [Date()]
            args.append(contentsOf: keys.map { $0 as (any DatabaseValueConvertible)? })
            try db.execute(sql: """
                UPDATE asset SET archived_at = ?
                WHERE id IN (\(placeholders)) AND archived_at IS NULL
                """, arguments: StatementArguments(args))
            return db.changesCount
        }
    }

    /// Take `assetIDs` off the shelf, in ONE transaction. Returns the number of
    /// rows that actually changed.
    ///
    /// The inverse of ``archive(_:)`` and lossless by construction: clearing the
    /// timestamp is the whole operation, because archiving never destroyed
    /// anything to restore. Filtered to `archived_at IS NOT NULL`, so
    /// unarchiving something that was never archived writes nothing.
    @discardableResult
    public func unarchive(_ assetIDs: [UUID]) async throws -> Int {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return 0 }
        return try await write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            try db.execute(sql: """
                UPDATE asset SET archived_at = NULL
                WHERE id IN (\(placeholders)) AND archived_at IS NOT NULL
                """, arguments: StatementArguments(keys))
            return db.changesCount
        }
    }

    /// The ids among `assetIDs` that are currently archived — the read half of a
    /// mixed selection, mirroring ``favoritedAssetIDs(among:)``. `ShelfIntent`
    /// (023 · A3) asks this to decide which way a mixed selection flips and to
    /// build the exact inverse an undo has to restore.
    public func archivedAssetIDs(among assetIDs: [UUID]) async throws -> Set<UUID> {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return [] }
        return try await read { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            let found = try String.fetchAll(db, sql: """
                SELECT id FROM asset
                WHERE id IN (\(placeholders)) AND archived_at IS NOT NULL
                """, arguments: StatementArguments(keys))
            return Set(found.compactMap(UUID.init(uuidString:)))
        }
    }

    /// What the archive shelf is holding (023 · A4 / 016 stats): how many items
    /// are on it, and how many bytes deleting all of them would actually free.
    ///
    /// This is the ONE read that deliberately looks at archived rows and reports
    /// them as their own figure rather than hiding or merging them. Archive
    /// creates the question "what can I reclaim", and the Library pane is where
    /// that question is asked.
    ///
    /// `exclusiveBytes` counts a blob only when EVERY asset referencing it is
    /// archived — which is the honest answer, and the reason it is not a simple
    /// `SUM(file_size)`. Blobs are shared (one file, many asset rows), so
    /// summing per-asset sizes would double-count a picture saved into three
    /// collections, and counting a blob an un-archived asset still points at
    /// would promise space that unarchiving nothing could release. A number in a
    /// "reclaim" row that overstates is worse than no number.
    public func archivedUsage() async throws -> ArchivedUsage {
        try await read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM asset WHERE archived_at IS NOT NULL") ?? 0
            // Per DISTINCT blob: keep it only if no un-archived asset references
            // it, then add its size once. `MAX(file_size)` collapses the rows
            // sharing a hash — they carry the same bytes by construction, so any
            // aggregate would do; MAX is the one that cannot return NULL while a
            // size exists.
            let bytes = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(size), 0) FROM (
                    SELECT MAX(file_size) AS size
                    FROM asset
                    WHERE blob_hash IS NOT NULL
                    GROUP BY blob_hash
                    HAVING SUM(CASE WHEN archived_at IS NULL THEN 1 ELSE 0 END) = 0
                )
                """) ?? 0
            return ArchivedUsage(assetCount: count, exclusiveBytes: bytes)
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

    /// The shared body behind ``collectionCovers(_:)`` and ``spaceCovers(_:)``,
    /// which are the same query over two parent tables: given a parent carrying
    /// `cover_asset_id`, map each requested id that HAS a surviving, byte-backed
    /// cover to that asset's `blob_hash`. Parents with no cover — or a cover asset
    /// that was deleted (`SET NULL`) — are simply absent from the result.
    ///
    /// An ARCHIVED cover is treated exactly like a deleted one (023 · A, edge
    /// case 1). A deleted cover is handled by the schema (`SET NULL`); an
    /// archived cover is not null, so without the predicate the card would keep
    /// rendering a picture of an item the user has put out of sight. Filtered
    /// out here, the parent is simply absent from the result and the gallery
    /// falls back to its most-recent non-archived member — the same fallback a
    /// deleted cover already gets, reached by the same route.
    ///
    /// `table` is interpolated into the SQL, so it must stay a compile-time
    /// literal from the call sites below and never user input; only the ids bind
    /// as arguments.
    private static func covers(
        in db: Database, table: String, ids: [UUID]
    ) throws -> [UUID: String] {
        let keys = ids.map(Self.key)
        guard !keys.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(table).id AS pid, asset.blob_hash AS hash
            FROM \(table)
            JOIN asset ON asset.id = \(table).cover_asset_id
            WHERE \(table).id IN (\(databaseQuestionMarks(count: keys.count)))
              AND asset.blob_hash IS NOT NULL
              AND asset.archived_at IS NULL
            """, arguments: StatementArguments(keys))
        var covers: [UUID: String] = [:]
        for row in rows {
            guard let pid = UUID(uuidString: row["pid"]) else { continue }
            covers[pid] = row["hash"]
        }
        return covers
    }

    /// The shared body behind ``collectionStackPreviews(limit:includeUnsorted:)``
    /// and ``spaceStackPreviews(limit:)`` (009 · N4). Both gallery cards want the
    /// same two things about a set of parents the caller has already fetched in
    /// its own order: the DIRECT item count, and the blob hashes of the `limit`
    /// most recently added byte-backed items, newest first. The pair differs only
    /// in the child table, its foreign key and its recency column, so those are
    /// parameters. One window-function query, not a per-parent N+1.
    ///
    /// Rows whose `asset_id` is NULL (a Space's element rows) or whose asset has
    /// no blob (media-less kinds, 003 · O1) still COUNT but cannot fan, which the
    /// `JOIN` + `blob_hash IS NOT NULL` gives for free.
    ///
    /// BOTH queries are scoped to `parentIDs`, which is what the caller is about
    /// to render. Unscoped, the count aggregate walked every collection in the
    /// library on each Home render and Swift threw the surplus away.
    ///
    /// `childTable` / `parentColumn` / `recencyColumn` are interpolated into the
    /// SQL, so they must stay compile-time literals from the call sites and never
    /// user input; only the ids and `limit` bind as arguments.
    private static func stackPreviews(
        in db: Database, parentIDs: [UUID],
        childTable: String, parentColumn: String, recencyColumn: String,
        limit: Int
    ) throws -> (counts: [UUID: Int], hashes: [UUID: [String]]) {
        let keys = parentIDs.map(Self.key)
        guard !keys.isEmpty else { return ([:], [:]) }
        let placeholders = databaseQuestionMarks(count: keys.count)

        // The count JOINS `asset` — it did not need to before the shelf existed
        // (023 · A, edge case 3). A **LEFT** join, and the predicate admits a
        // missing asset: a Space's element rows carry a NULL `asset_id` and are
        // real items that must keep counting. An inner join would silently drop
        // every element row and the card would read "2 items" over a board of 3.
        var counts: [UUID: Int] = [:]
        let countRows = try Row.fetchAll(db, sql: """
            SELECT ch.\(parentColumn) AS pid, COUNT(*) AS cnt
            FROM \(childTable) ch
            LEFT JOIN asset a ON a.id = ch.asset_id
            WHERE ch.\(parentColumn) IN (\(placeholders))
              AND (a.id IS NULL OR a.archived_at IS NULL)
            GROUP BY ch.\(parentColumn)
            """, arguments: StatementArguments(keys))
        for row in countRows {
            guard let pid = UUID(uuidString: row["pid"]) else { continue }
            counts[pid] = row["cnt"]
        }

        guard limit > 0 else { return (counts, [:]) }
        var hashArgs = keys.map { $0 as any DatabaseValueConvertible }
        hashArgs.append(limit)
        // `<recency> DESC, id DESC` — the id tie-break keeps a same-instant
        // batch deterministic.
        var hashes: [UUID: [String]] = [:]
        let hashRows = try Row.fetchAll(db, sql: """
            SELECT pid, hash FROM (
                SELECT ch.\(parentColumn) AS pid, a.blob_hash AS hash,
                       ROW_NUMBER() OVER (
                           PARTITION BY ch.\(parentColumn)
                           ORDER BY ch.\(recencyColumn) DESC, ch.id DESC
                       ) AS rn
                FROM \(childTable) ch
                JOIN asset a ON a.id = ch.asset_id
                WHERE a.blob_hash IS NOT NULL
                  AND a.archived_at IS NULL
                  AND ch.\(parentColumn) IN (\(placeholders))
            ) WHERE rn <= ?
            ORDER BY pid, rn
            """, arguments: StatementArguments(hashArgs))
        for row in hashRows {
            guard let pid = UUID(uuidString: row["pid"]) else { continue }
            hashes[pid, default: []].append(row["hash"])
        }
        return (counts, hashes)
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

    // MARK: - Unsorted invariant (F3)
    //
    // "Unsorted" is the home for assets that live in NO real folder — not a
    // folder in its own right. Two rules keep that literally true, enforced here
    // rather than at the call sites so every funnel (app, capture server, item
    // detail chips, undo) inherits them inside the same transaction:
    //
    //   1. Filed ⇒ not unsorted. Gaining a real membership drops the Unsorted one.
    //   2. Unfiled ⇒ unsorted. Losing the last membership re-homes to Unsorted.
    //
    // Deliberately NOT applied by ``restoreDeletedAssets(_:)`` / snapshot restore,
    // which re-insert membership rows verbatim: undo must be an exact inverse, and
    // legacy both-places rows are the migration's job, not restore's.
    //
    // Migration v16 back-fills both rules over existing libraries, so the rules
    // describe the whole store, not just writes made since the upgrade.

    /// True when the asset belongs to at least one collection that is not
    /// Unsorted (and not `excluding`, a membership the caller is about to drop).
    private static func isFiled(
        _ db: Database, assetID: UUID, excluding: UUID? = nil
    ) throws -> Bool {
        var blocked = [key(Collection.unsortedID)]
        if let excluding { blocked.append(key(excluding)) }
        return try CollectionItem
            .filter(Column("asset_id") == key(assetID))
            .filter(!blocked.contains(Column("collection_id")))
            .fetchCount(db) > 0
    }

    /// Give the freshly ingested / deduped asset its ONE membership in
    /// `collectionID`, honoring the invariant. Shared by both ingest funnels,
    /// where it only ever bites on the 18A dedup path: a brand-new asset has no
    /// other membership to reconcile, but a re-capture of bytes already in the
    /// library resolves to an asset that may already be filed (→ skip the Unsorted
    /// row) or still unsorted (→ evict it as the folder membership lands).
    private static func placeIngested(
        _ db: Database, assetID: UUID, in collectionID: UUID, placement: CanvasPlacement?
    ) throws {
        let intoUnsorted = collectionID == Collection.unsortedID
        if intoUnsorted, try isFiled(db, assetID: assetID) { return }
        let alreadyMember = try membership(
            db, collectionID: collectionID, assetID: assetID) != nil
        if !alreadyMember {
            let item = CollectionItem(
                id: UUID(), collectionID: collectionID, assetID: assetID,
                addedAt: Date(),
                manualOrder: try nextManualOrder(db, collectionID: collectionID),
                canvasX: placement?.x, canvasY: placement?.y,
                canvasW: placement?.w, canvasH: placement?.h, canvasZ: placement?.z)
            try item.insert(db)
        }
        if !intoUnsorted {
            try evictFromUnsorted(db, assetIDs: [assetID])
        }
    }

    /// Drop each listed asset's Unsorted membership — rule 1. Idempotent; a
    /// non-member is a no-op.
    ///
    /// Returns the assets that ACTUALLY held one, which is not the input: the
    /// caller passes a whole batch and most of it is usually filed already. The
    /// rows are read before the delete because afterwards there is nothing left to
    /// ask (356).
    @discardableResult
    private static func evictFromUnsorted(_ db: Database, assetIDs: [UUID]) throws -> [UUID] {
        guard !assetIDs.isEmpty else { return [] }
        let keys = assetIDs.map(key)
        let doomed = CollectionItem
            .filter(Column("collection_id") == key(Collection.unsortedID))
            .filter(keys.contains(Column("asset_id")))
        let evicted = try doomed.fetchAll(db).map(\.assetID)
        try doomed.deleteAll(db)
        return evicted
    }

    /// Give each listed asset that now has NO membership at all an Unsorted one —
    /// rule 2. Appended to Unsorted's manual order in batch order, matching
    /// ``addAssets(_:to:)``. Unknown / since-deleted ids are skipped.
    private static func rehomeUnfiled(_ db: Database, assetIDs: [UUID]) throws {
        guard !assetIDs.isEmpty else { return }
        let now = Date()
        var order = try nextManualOrder(db, collectionID: Collection.unsortedID)
        var seen: Set<UUID> = []
        for assetID in assetIDs where seen.insert(assetID).inserted {
            guard try Asset.exists(db, key: key(assetID)) else { continue }
            let stillFiled = try CollectionItem
                .filter(Column("asset_id") == key(assetID))
                .fetchCount(db) > 0
            if stillFiled { continue }
            let item = CollectionItem(
                id: UUID(), collectionID: Collection.unsortedID,
                assetID: assetID, addedAt: now, manualOrder: order)
            try item.insert(db)
            order += 1
        }
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
