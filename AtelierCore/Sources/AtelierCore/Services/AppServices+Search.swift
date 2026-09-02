// AtelierCore — AppServices: keyword search (the P0 file split).
//
// `searchAssets` and the ordering helper it hydrates through: the bounded FTS5
// path, its trigram substring arm, and every structured filter that narrows it.
// The MEANING-based counterpart (`semanticSearchAssets`) is in
// `AppServices+Analysis.swift`, with the embedding lane it reads. Moved verbatim
// out of `AppServices.swift` — same code, same order, same comments.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

import Foundation
import GRDB

extension AppServices {

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
}
