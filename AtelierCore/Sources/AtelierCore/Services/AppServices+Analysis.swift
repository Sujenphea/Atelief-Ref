// AtelierCore — AppServices: derived analysis (the P0 file split).
//
// The three derived-data lanes, in the order they were written: Vision's OCR +
// classification row (012 · I1), the colour buckets the chips filter on
// (085 · C1), and the text embeddings meaning-search ranks over (047 · 3a).
//
// `semanticSearchAssets` lives HERE and not in `+Search.swift`, because it is the
// read half of the embedding lane — it shares the model-version rule, the vector
// codec and the L2-normalization contract with the writers above it, and nothing
// with the FTS query builder. Moved verbatim; same code, same order.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

// Accelerate is no longer imported here: the dot products moved to
// `EmbeddingCorpus.swift` with the matrix they run over (099 · P0b).
import Foundation
import GRDB

extension AppServices {

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
        let analyzedAt = Date()
        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            var row = AssetAnalysis(
                assetID: assetID, ocrText: ocrText, colors: colors, phash: phash,
                analyzedAt: analyzedAt, analyzerVersion: analyzerVersion,
                // v23: the monotonic marker the embedding backfill compares on. Taken
                // inside this write, and `write` is serialized, so two analyses cannot
                // draw the same number — which is the whole point, since the timestamps
                // they used to be compared by tie at millisecond resolution.
                analysisSeq: try Self.nextAnalysisSeq(db))
            let existing = try AssetAnalysis
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchOne(db)
            if let existing {
                // `suggest_version` SURVIVES a re-analysis; `colors_palette_version`
                // deliberately does not (012 · I3). The difference is whether this
                // write invalidates the derived thing: new `colors` make the filed
                // buckets stale by definition, so clearing that marker re-derives
                // them. Classification reads the same pixels as before and knows
                // nothing about OCR, so carrying its marker over is what keeps the
                // two versions independent — otherwise every analyzer bump silently
                // becomes a suggester bump too, which is exactly the coupling v22
                // split them to avoid.
                row.suggestVersion = existing.suggestVersion
                try row.update(db)
            } else {
                try row.insert(db)
            }
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
    /// Media-less kinds are excluded (they have no bytes to analyze), so they never
    /// linger as perpetually-pending — the batch drains to empty and stays there
    /// until new media arrives or the analyzer version bumps. No ledger needed:
    /// "still needs analysis" is expressible as this one LEFT JOIN, so a killed
    /// backfill resumes simply by re-running it.
    ///
    /// **Video is IN**, and the exclusion this used to carry ("whose analysis needs
    /// a poster-frame path, deferred") was more pessimistic than the tree: the
    /// poster frame is generated at INGEST and has been sitting on disk as a JPEG
    /// tier ever since. The backfill reads that instead of the movie
    /// (`AnalysisBackfill.imageData(for:)`), so video gains OCR, colors and a hash
    /// without the frame-sampling project 012 assumed it would cost. Until this
    /// changed, a video's Colors section was permanently empty and no suggestion
    /// could ever reach it.
    public func assetsNeedingAnalysis(analyzerVersion: Int, limit: Int) async throws -> [UUID] {
        let clampedLimit = min(max(limit, 1), 1000)
        return try await read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT a.id
                FROM asset a
                LEFT JOIN asset_analysis an ON an.asset_id = a.id
                WHERE a.kind IN (?, ?)
                  AND a.blob_hash IS NOT NULL
                  AND a.download_state = ?
                  AND (an.asset_id IS NULL OR an.analyzer_version < ?)
                ORDER BY a.created_at DESC
                LIMIT ?
                """, arguments: [
                    AssetKind.image.rawValue,
                    AssetKind.video.rawValue,
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
        let encoded = AssetEmbedding.encode(vector)
        let embeddedAt = Date()
        let written = try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            // Built INSIDE the write so the analysis marker can be read in the same
            // serialized transaction (and because a `var` cannot cross into a sendable
            // closure). Recording WHICH analysis this embedding accounted for (v23) is
            // what lets an analysis landing a moment later still re-qualify the asset.
            let row = AssetEmbedding(
                assetID: assetID, modelVersion: modelVersion, contentHash: contentHash,
                vector: encoded, embeddedAt: embeddedAt,
                analysisSeq: try Self.currentAnalysisSeq(db, assetID: assetID))
            let exists = try AssetEmbedding
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchCount(db) > 0
            if exists { try row.update(db) } else { try row.insert(db) }
            return row
        }
        // One of the TWO writers that can change what the resident corpus holds
        // (099 · P0b). AFTER the commit, not inside it: an invalidation issued
        // before the write lands would let a reader in the pre-commit snapshot
        // re-publish the very corpus this is clearing, and nothing would clear it
        // a second time. See ``EmbeddingCorpusCache`` for the window this leaves
        // and why it is survivable.
        corpusCache.invalidate()
        return written
    }

    /// The next analysis marker: greater than any issued before. Read inside the
    /// caller's write so it is serialized with every other analysis write.
    private static func nextAnalysisSeq(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COALESCE(MAX(analysis_seq), 0) + 1 FROM asset_analysis
            """) ?? 1
    }

    /// The marker on `assetID`'s current analysis, or nil when it has none.
    private static func currentAnalysisSeq(_ db: Database, assetID: UUID) throws -> Int? {
        try Int.fetchOne(db, sql: """
            SELECT analysis_seq FROM asset_analysis WHERE asset_id = ?
            """, arguments: [Self.key(assetID)])
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
                       OR (an.analysis_seq IS NOT NULL
                           AND (e.analysis_seq IS NULL OR an.analysis_seq > e.analysis_seq)))
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
            // Also adopt the current analysis marker (v23). Bumping only `embedded_at`
            // would leave the asset re-qualifying forever once an analysis had drawn a
            // higher number: the touch is the acknowledgement that this analysis was
            // looked at and its text was unchanged, so it has to be recorded as such.
            try db.execute(sql: """
                UPDATE asset_embedding SET embedded_at = ?, analysis_seq = ?
                WHERE asset_id = ?
                """, arguments: [
                    Date(), try Self.currentAnalysisSeq(db, assetID: assetID),
                    Self.key(assetID),
                ])
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
    /// Ranking is Swift-side brute-force cosine (SQLite has no vector index), in
    /// three steps, and **the split between them is the whole of 099 · P0b**:
    ///
    /// 1. **Scope, in SQL, live.** The predicates below narrow to the in-scope
    ///    asset IDS — no vectors. This runs on every call against the current
    ///    snapshot, so membership, the archive shelf and every filter are as
    ///    fresh as they ever were. Nothing about them is cached, ever.
    /// 2. **Vectors, from memory.** ``EmbeddingCorpusCache`` holds one contiguous
    ///    row-major matrix of every embedding at this `(modelVersion, width)`,
    ///    loaded once and reused. The two sets are intersected by id.
    /// 3. **Top-k by partial selection.** A bounded heap (``TopKSelector``), not a
    ///    sort of the whole corpus followed by a `prefix`.
    ///
    /// The ORDER is unchanged and must stay so: score descending, then id
    /// ascending, so equal scores rank deterministically.
    ///
    /// What step 1 being live buys, and it is the property that matters: **a
    /// stale corpus cannot resurrect a deleted or archived asset.** It is not
    /// consulted about what exists. The worst a stale corpus can do is rank an
    /// asset against a vector one re-embed old, or miss an asset embedded in the
    /// last few microseconds — and the invalidation from the two writers closes
    /// even that.
    ///
    /// Memory: **2 KB per embedded asset, resident** (512 × Float32), so ~40 MB
    /// at 20,000. Unbounded by design — see ``EmbeddingCorpusCache``.
    ///
    /// Still NOT keyset-pageable (relevance order isn't the recency cursor's
    /// order) — `limit` only.
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

        let dimensions = queryVector.count
        let cache = corpusCache

        return try await read { db in
            // 1. In-scope candidates (8A). These structured predicates mirror the
            //    same filters in `searchAssets` (platform / collection membership /
            //    tag set semantics) — kept as focused SQL here rather than sharing
            //    the FTS query builder, since this path has no text arms.
            //
            //    It selects IDS ONLY now. Selecting `e.vector` alongside them was
            //    the 77 µs per asset P0 measured: 20,000 BLOBs read, copied and
            //    decoded to answer a query that keeps fifty of them.
            var sql = """
                SELECT e.asset_id AS asset_id
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

            let candidateKeys = try String.fetchAll(
                db, sql: sql, arguments: StatementArguments(args))
            guard !candidateKeys.isEmpty else { return [] }

            // 2. The resident corpus, loaded on a miss INSIDE this same read, so
            //    the vectors and the candidate set come from one snapshot rather
            //    than two — the single-transaction guarantee the un-cached query
            //    had, kept.
            let corpus = try cache.corpus(modelVersion: modelVersion, dimensions: dimensions) {
                try Self.loadEmbeddingCorpus(
                    db, modelVersion: modelVersion, dimensions: dimensions)
            }

            // 3. Cosine = dot product (both sides L2-normalized). Query
            //    normalization only scales all scores by |query|, which doesn't
            //    change the ranking, so a non-unit query still orders correctly.
            //    Nearest first, ascending-id tiebreak, top `clampedLimit` — the
            //    same order the full sort produced, selected without one.
            let topIDs = corpus.topMatches(
                query: queryVector, candidateKeys: candidateKeys, limit: clampedLimit)
            guard !topIDs.isEmpty else { return [] }

            // 4. Hydrate details and restore the ranked order (the IN fetch is
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

    /// Read every embedding at `modelVersion` whose vector is exactly
    /// `dimensions` floats wide into one resident matrix (099 · P0b).
    ///
    /// **A cursor, not `fetchAll`.** `fetchAll` would hold 20,000 live `Data`
    /// blobs — 40 MB of them — at the same moment as the 40 MB matrix they are
    /// being copied into, doubling the peak for no reason. Streamed, one blob is
    /// alive at a time.
    ///
    /// **The width filter is in SQL** (`length(vector) = dimensions * 4`) rather
    /// than in Swift, so a library holding two vector shapes under one model
    /// version — a half-finished re-embed at a new width — loads only the rows a
    /// query of THIS width could have scored. That is exactly what the un-cached
    /// path did per row, moved to where it costs nothing.
    ///
    /// The `COUNT(*)` in front saves the matrix from growing by doubling through
    /// twenty reallocations and copies of up to 40 MB. It deliberately does NOT
    /// repeat the width filter: `model_version` alone is answerable from
    /// `index_asset_embedding_on_model_version` without touching a row, while
    /// `length(vector)` would drag the whole table through a second pass to
    /// sharpen a number that only has to be an upper bound.
    ///
    /// This reads `asset_embedding`, never `asset`: what EXISTS is decided by the
    /// live candidate query in ``semanticSearchAssets(queryVector:modelVersion:platform:tagIDs:tagMatch:collectionIDs:favoritesOnly:colorBuckets:colorMatch:minimumColorCoverage:limit:)``,
    /// which is why a row here for a since-deleted asset could never surface one.
    private static func loadEmbeddingCorpus(
        _ db: Database, modelVersion: Int, dimensions: Int
    ) throws -> EmbeddingCorpus {
        let byteWidth = dimensions * 4
        let expected = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM asset_embedding WHERE model_version = ?
            """, arguments: [modelVersion]) ?? 0
        var builder = EmbeddingCorpusBuilder(
            modelVersion: modelVersion, dimensions: dimensions, expectedRows: expected)
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT asset_id, vector FROM asset_embedding
            WHERE model_version = ? AND length(vector) = ?
            """, arguments: [modelVersion, byteWidth])
        while let row = try cursor.next() {
            guard let key: String = row["asset_id"], let vector: Data = row["vector"] else {
                continue
            }
            builder.append(key: key, vector: vector)
        }
        return builder.finish()
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
}
