// AtelierCore — the public App Services surface: the class, the funnel, the
// shared helpers (chunk 5, A2/A4/C6)
//
// The ONE public type of the package (A2). Every mutation in the app routes
// through this class's single `write {}` funnel (A4): validation (C8) and
// invariants (C6) run inside or before each transaction, never bypassed, and
// GRDB errors are mapped to `AtelierError` on the way out (C7) so the toolkit
// never leaks.
//
// **The surface is one type spread over nine files** (099 · P0). This file kept
// the class, its three funnel doors, and the helpers more than one subject uses;
// each `// MARK:` section that was here moved WHOLE and unchanged into its own
// extension:
//
//     AppServices+Collections.swift   folders, arrange / bulk, the scoped reads
//     AppServices+Assets.swift        ingest, delete + undo, fields, shelf, tags
//     AppServices+Spaces.swift        boards and their items
//     AppServices+Search.swift        keyword search
//     AppServices+SavedSearches.swift smart collections
//     AppServices+Analysis.swift      OCR / colours / embeddings, and meaning search
//     AppServices+Jobs.swift          the bulk-import ledger
//     AppServices+Library.swift       snapshots, integrity, storage stats
//
// **What the split cost, stated plainly.** A Swift extension in another file
// cannot see `private`, so the funnel and the helpers those extensions call are
// now `internal`. `database` is NOT — it is still private to this file, which is
// what keeps "every mutation goes through the funnel" a fact the compiler checks
// rather than a habit. Nothing else in the package can reach the pool.

import Foundation
import GRDB

/// The public, `Sendable` write surface over the internal ``LibraryDatabase``.
///
/// `final class … Sendable` (A3): both stored properties are `Sendable` and both
/// are `let`. All mutations are `async` and serialized by the underlying
/// `DatabasePool` writer (WAL).
///
/// **One of them is a cache, and that is new** (099 · P0b). This class carried no
/// in-memory state at all until the semantic corpus arrived, and the property
/// below is the single exception: a mutex-guarded slot holding the embedding
/// matrix meaning-search ranks over. It is not a general memoization layer and
/// must not become one — it caches DERIVED numbers, never rows, and the queries
/// that decide what a user may SEE still run live against SQLite on every call.
/// See ``EmbeddingCorpusCache``.
public final class AppServices: Sendable {
    /// The internal store. Never exposed — only the funnel touches its pool, and
    /// `private` here means only THIS file can, which is why the funnel grew a
    /// third door (``writeWithoutTransaction(_:)``) rather than widening this
    /// when the surface was split across files.
    private let database: LibraryDatabase

    /// The resident embedding corpus (099 · P0b), loaded on the first meaning
    /// search and invalidated by the two writers that can change it —
    /// ``upsertEmbedding(assetID:modelVersion:contentHash:vector:)`` and the
    /// asset delete. `internal`, not `private`, because the reader lives in
    /// `AppServices+Analysis.swift` and the two invalidation sites in
    /// `+Analysis.swift` and `+Collections.swift` / `+Assets.swift`; unlike
    /// `database` there is no invariant that widening spends, because a cache
    /// reachable from another file in the package cannot bypass a transaction.
    let corpusCache = EmbeddingCorpusCache()

    /// Open (or create) a library at `databasePath`, migrated to the latest
    /// schema.
    public init(databasePath: String) throws {
        self.database = try LibraryDatabase(path: databasePath)
    }

    /// Open (or create, and migrate) the library rooted at `libraryRoot` — the database
    /// at ``databaseURL(in:)``.
    ///
    /// The one composition of ``AtelierCore/databaseFileName`` with a root (457). Every
    /// host that opens a library has a ROOT — `LibraryLocation` hands one out, `blobs/`
    /// and `thumbnails/` hang off it — and three of them had spelled the join to the
    /// database file by hand. Three spellings of one path is how a phone and a Mac end
    /// up opening two different files under one root.
    public static func open(libraryRoot: URL) throws -> AppServices {
        try AppServices(databasePath: databaseURL(in: libraryRoot).path)
    }

    /// `<libraryRoot>/library.sqlite` — where ``open(libraryRoot:)`` opens. Pure path
    /// arithmetic, exposed so a caller that only needs to LOOK (a storage scan, a test
    /// asserting where the file went) asks the same authority the opener does.
    public static func databaseURL(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(AtelierCore.databaseFileName, isDirectory: false)
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
    func write<T: Sendable>(
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
    func read<T: Sendable>(
        _ op: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.pool.read(op)
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    /// The funnel's third door, for the statements SQLite refuses to run inside a
    /// transaction — `VACUUM INTO` is the only one today. Same error mapping as
    /// the other two, so a caller cannot tell the difference from the outside.
    ///
    /// It exists so `snapshot(to:)` can live in `AppServices+Library.swift`
    /// without `database` having to widen to `internal`. That matters: `database`
    /// being the ONE private stored property is what makes "every mutation goes
    /// through the funnel" (A4) a fact the compiler checks rather than a habit,
    /// and the file split must not spend that to save a file move.
    func writeWithoutTransaction<T: Sendable>(
        _ op: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.pool.writeWithoutTransaction(op)
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    /// Fetch a row by primary key, or throw ``AtelierError/notFound(entity:id:)``.
    ///
    /// Twenty-three sites spelled this as a five-line `guard let … else { throw }`,
    /// each one repeating the id-to-key conversion and the entity string. They are
    /// this call now. `entity` defaults to the record's own table name, which is
    /// what every one of those sites passed by hand — `Collection` said
    /// `"collection"`, `SpaceItem` said `"space_item"` — so the default is not a
    /// guess, it is the string that was already there.
    ///
    /// The parameter survives for the case that needs to differ: a lookup whose
    /// FAILURE the caller wants reported as a different entity than the table it
    /// read (`setCanvasPlacement` reports a missing membership as
    /// `"collection_item"` while looking up by asset id).
    static func require<T: FetchableRecord & TableRecord>(
        _ type: T.Type,
        db: Database,
        key id: UUID,
        entity: String = T.databaseTableName
    ) throws -> T {
        guard let row = try T.fetchOne(db, key: Self.key(id)) else {
            throw AtelierError.notFound(entity: entity, id: id)
        }
        return row
    }

    // MARK: - Shared query helpers
    //
    // Private until the surface was split (099 · P0); `internal` now, because an
    // extension in another file cannot see `private` and these are precisely the
    // pieces more than one subject needs. They remain package-internal — nothing
    // outside AtelierCore can call them — and none of them touches `database`.

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
    static func covers(
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
    static func stackPreviews(
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
    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The (collection, asset) membership row, if any.
    static func membership(
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
    static func isFiled(
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
    static func placeIngested(
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
    static func evictFromUnsorted(_ db: Database, assetIDs: [UUID]) throws -> [UUID] {
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
    static func rehomeUnfiled(_ db: Database, assetIDs: [UUID]) throws {
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
    static func findDuplicate(
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
    static func findDuplicateContent(
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
