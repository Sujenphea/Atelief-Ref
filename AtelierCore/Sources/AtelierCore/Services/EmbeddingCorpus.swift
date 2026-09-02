// AtelierCore — the resident semantic corpus (099 · P0b)
//
// P0 measured `semanticSearchAssets` at 1,547 ms over 20,000 vectors — dead
// linear at ~77 µs each, fifteen times the ~100 ms the plan set as the point
// where a cache is worth its memory. The shape of that curve said where the time
// was NOT: there is no fixed cost above ~26 ms, so the full `n log n` sort was
// never the dominant term. **Decoding 20,000 × 512 Float32 out of 20,000 BLOBs,
// on every keystroke, was.**
//
// So this file holds the corpus resident instead, in the one layout the maths
// wants: ONE contiguous `[Float]`, row-major, `dimensions` wide, with a parallel
// `ids` array and a key → row index. Loaded on the first query, reused by every
// query after it, dropped whole the moment either writer touches an embedding.
//
// ## What it costs, plainly
//
// **2 KB per asset, resident** — 512 floats × 4 bytes — so a 20,000-item library
// holds ~40 MB of matrix for as long as the process lives, plus roughly 2 MB for
// the `ids` array and the key index. There is NO eviction policy and no bound:
// the plan did not ask for one, and a bound that drops the corpus mid-session
// would hand the user back the 1.5-second query it exists to remove. A library
// an order of magnitude larger than the 20k the harness measures would want one;
// 099 · P0b's changelog says so rather than this file inventing it.
//
// ## The two properties that make this safe
//
// 1. **The SQL pre-filter still runs, every query.** The cache never answers
//    "which assets are in scope" — that stays a live query against `asset`, with
//    the archive predicate, the collection / tag / colour / favourite conjuncts
//    and the model-version gate exactly as before. The corpus only answers "what
//    is this asset's vector", and the two are intersected. A deleted asset is
//    therefore unreachable through a stale corpus: it left the candidate set the
//    moment the row died, whatever this cache still believes.
// 2. **A load that raced a write is refused, not published.** Loading 40 MB
//    takes long enough that a write can commit underneath it. Every load reads
//    the cache's generation first and publishes only if it has not moved, so the
//    corpus that lands is never older than the last invalidation.
//
// The residual window is stated where it lives, on ``EmbeddingCorpusCache``.

import Accelerate
import Foundation
import Synchronization

// MARK: - The corpus

/// Every embedding vector at one `(modelVersion, dimensions)`, resident, in the
/// layout `vDSP` wants: one contiguous row-major matrix rather than N separate
/// arrays.
///
/// **Keyed by `dimensions` as well as `modelVersion`**, because that is what
/// makes the cached path byte-for-byte the uncached one. The query before this
/// change scored a stored vector only when `vector.count == queryVector.count`
/// and skipped the rest; folding the width into the key reproduces that exactly
/// — a corpus is the set of rows a query of THAT width would have scored — and
/// it means a 3-float test vector and a 512-float production vector under one
/// model version cannot contaminate each other.
///
/// `rowIndex` is keyed by the STORED key form (`AppServices.key`, a lowercased
/// uuidString) rather than by `UUID`, so the per-query intersection never parses
/// a uuid: the candidate ids arrive from SQLite as exactly those strings. The
/// `UUID`s the caller gets back are parsed once, at load, into ``ids``.
struct EmbeddingCorpus: Sendable {
    /// The model version every row was produced by. A query at another version
    /// is a different corpus, never a filtered view of this one.
    let modelVersion: Int
    /// The width of every row in ``matrix``. Also the query width this corpus
    /// can answer at all.
    let dimensions: Int
    /// Row → asset id, parallel to ``matrix``'s rows.
    let ids: [UUID]
    /// The vectors, row-major: row `r` occupies `matrix[r * dimensions ..< (r + 1) * dimensions]`.
    /// ONE allocation — an array of arrays would put a pointer chase and a
    /// retain/release between every dot product.
    let matrix: [Float]
    /// Stored key (lowercased uuidString) → row.
    let rowIndex: [String: Int]

    /// How many vectors are resident.
    var count: Int { ids.count }

    /// Approximate resident bytes — the number 099 · P0b asks to be stated,
    /// computed rather than claimed. Matrix + ids + a rough index estimate.
    var approximateBytes: Int {
        matrix.count * MemoryLayout<Float>.stride
            + ids.count * MemoryLayout<UUID>.stride
            + rowIndex.count * 96
    }

    /// The top `limit` candidate rows by cosine similarity to `query`, best first.
    ///
    /// `candidateKeys` is the SQL pre-filter's answer — the in-scope assets, in
    /// whatever order SQLite produced them. A key this corpus does not know is
    /// SKIPPED, for either of the two reasons it can be missing: its stored
    /// vector is not this width (the un-cached path skipped those per row, for
    /// the same reason), or its embedding was written since the corpus loaded
    /// (which invalidation is what prevents). Neither is worth a crash, and
    /// neither can show the caller an asset that is not in scope.
    ///
    /// Both sides are L2-normalized at the analyzer seam, so the dot product IS
    /// the cosine; a non-unit query scales every score alike and does not change
    /// the ranking. Selection is ``TopKSelector`` — O(n log k) with k ≤ 500 —
    /// rather than sorting the whole corpus and taking a prefix.
    ///
    /// A query whose width is not this corpus's returns nothing, which is what
    /// the uncached path did by skipping every mismatched row.
    func topMatches(query: [Float], candidateKeys: [String], limit: Int) -> [UUID] {
        guard limit > 0, !ids.isEmpty, query.count == dimensions,
              !candidateKeys.isEmpty
        else { return [] }

        var selector = TopKSelector(limit: limit)
        query.withUnsafeBufferPointer { q in
            matrix.withUnsafeBufferPointer { m in
                guard let queryBase = q.baseAddress, let matrixBase = m.baseAddress else { return }
                let width = vDSP_Length(dimensions)
                for key in candidateKeys {
                    guard let row = rowIndex[key] else { continue }
                    var score: Float = 0
                    vDSP_dotpr(queryBase, 1, matrixBase + row * dimensions, 1, &score, width)
                    selector.offer(id: ids[row], score: score)
                }
            }
        }
        return selector.ranked()
    }
}

// MARK: - Building one

/// Accumulates stored rows into ``EmbeddingCorpus``'s flat matrix as they stream
/// out of SQLite.
///
/// A builder rather than an initialiser taking an array, because the array would
/// be 20,000 live `Data` blobs — 40 MB of them — held at once purely to be
/// copied into 40 MB of matrix. Fed from a GRDB cursor, only one blob is alive
/// at a time.
///
/// **The matrix is allocated ONCE, up front, and written by row.** That is the
/// difference between a cold search that beats the un-cached query and one that
/// does not: growing the matrix a row at a time — however the row is decoded —
/// dominated the load, and the load is what the first search after launch pays.
/// `expectedRows` comes from a `COUNT(*)` the loader runs first; it is an upper
/// bound, and an overshoot is trimmed by ``finish()``.
struct EmbeddingCorpusBuilder {
    private let modelVersion: Int
    private let dimensions: Int
    private let byteWidth: Int
    private var ids: [UUID] = []
    private var rowIndex: [String: Int] = [:]
    /// `capacityRows * dimensions` floats. The first `ids.count` rows are live.
    private var matrix: [Float]
    private var capacityRows: Int

    /// Rows ``append(key:vector:)`` refused, and why they are counted rather
    /// than thrown: see that method.
    private(set) var skipped = 0

    init(modelVersion: Int, dimensions: Int, expectedRows: Int = 0) {
        self.modelVersion = modelVersion
        self.dimensions = dimensions
        self.byteWidth = dimensions * MemoryLayout<Float>.size
        self.capacityRows = max(expectedRows, 0)
        self.matrix = [Float](repeating: 0, count: capacityRows * max(dimensions, 0))
        ids.reserveCapacity(capacityRows)
        rowIndex.reserveCapacity(capacityRows)
    }

    /// Append one stored row, or count a skip.
    ///
    /// **A malformed row is SKIPPED, never thrown.** Three shapes are refused: a
    /// key that is not a uuid, a blob that is not exactly `dimensions * 4` bytes,
    /// and a key already appended. The reason is that `asset_embedding.vector` is
    /// DERIVED data — a re-embed rewrites it — so one bad row is a row the next
    /// backfill pass fixes, while a throw here would take the whole library's
    /// meaning search down until someone found it. It is also precisely what the
    /// uncached path did: it skipped any vector whose length did not match the
    /// query's and carried on ranking the rest.
    ///
    /// A zero-width corpus refuses everything — there is no such thing as a
    /// vector with no lanes, and the query guards an empty query before it ever
    /// gets here.
    ///
    /// - Returns: whether the row was taken.
    @discardableResult
    mutating func append(key: String, vector: Data) -> Bool {
        guard dimensions > 0, vector.count == byteWidth, let id = UUID(uuidString: key),
              rowIndex[key] == nil
        else {
            skipped += 1
            return false
        }
        let row = ids.count
        if row == capacityRows {
            // Only reachable when `expectedRows` under-counted — it is a
            // `COUNT(*)` at the same model version, so a wider count than the
            // width filter admits, and it cannot. Doubling rather than trapping
            // keeps a surprise here from being a crash in a search field.
            let grown = max(capacityRows * 2, row + 1)
            matrix.append(
                contentsOf: [Float](repeating: 0, count: (grown - capacityRows) * dimensions))
            capacityRows = grown
        }
        matrix.withUnsafeMutableBufferPointer { buffer in
            AssetEmbedding.copyVector(vector, into: UnsafeMutableBufferPointer(
                rebasing: buffer[(row * dimensions)..<((row + 1) * dimensions)]))
        }
        rowIndex[key] = row
        ids.append(id)
        return true
    }

    consuming func finish() -> EmbeddingCorpus {
        var matrix = self.matrix
        let used = ids.count * dimensions
        if matrix.count > used { matrix.removeLast(matrix.count - used) }
        return EmbeddingCorpus(
            modelVersion: modelVersion, dimensions: dimensions,
            ids: ids, matrix: matrix, rowIndex: rowIndex)
    }
}

// MARK: - Top-k by partial selection

/// Keeps the best `limit` `(id, score)` pairs seen, and nothing else.
///
/// A bounded min-heap: the ROOT is the worst of the kept, so an offer that
/// cannot beat it is rejected in one comparison. O(n log k) with k ≤ 500 against
/// the full sort's O(n log n) over the whole corpus — and, more to the point, it
/// never allocates an array of 20,000 scores to throw 19,950 of them away.
///
/// The order is the one `semanticSearchAssets` has always used and must keep
/// exactly: **score descending, then id ascending in `uuidString` order** so
/// equal scores rank deterministically. See ``precedes(_:_:)`` for why the
/// tiebreak compares bytes rather than strings.
struct TopKSelector {
    private let limit: Int
    private var heap: [(id: UUID, score: Float)] = []

    init(limit: Int) {
        self.limit = max(limit, 0)
        if self.limit > 0 { heap.reserveCapacity(self.limit) }
    }

    /// True when `lhs` outranks `rhs`: a higher score, or an equal score and a
    /// lower id.
    static func outranks(_ lhs: (id: UUID, score: Float), _ rhs: (id: UUID, score: Float)) -> Bool {
        lhs.score != rhs.score ? lhs.score > rhs.score : precedes(lhs.id, rhs.id)
    }

    /// True when `lhs` sorts before `rhs` in `uuidString` order — compared over
    /// the raw 16 bytes rather than by building two strings.
    ///
    /// The two orders are the same, and not by luck: `uuidString` is the bytes
    /// rendered as fixed-width hex with the dashes at fixed positions, so both
    /// strings agree on where the separators are, and within a nibble the ASCII
    /// order of `0`–`9` then `A`–`F` matches the numeric order of the values
    /// they stand for. Byte order therefore IS string order — and the test says
    /// so against `uuidString` over random pairs, because that is the kind of
    /// claim that should not be taken on trust.
    ///
    /// It matters because the alternative allocates: `UUID.uuidString` builds a
    /// fresh `String` on every call, and the tiebreak is reached on every exact
    /// score tie in a 20,000-row scan.
    static func precedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let l = lhs.uuid, r = rhs.uuid
        if l.0 != r.0 { return l.0 < r.0 }
        if l.1 != r.1 { return l.1 < r.1 }
        if l.2 != r.2 { return l.2 < r.2 }
        if l.3 != r.3 { return l.3 < r.3 }
        if l.4 != r.4 { return l.4 < r.4 }
        if l.5 != r.5 { return l.5 < r.5 }
        if l.6 != r.6 { return l.6 < r.6 }
        if l.7 != r.7 { return l.7 < r.7 }
        if l.8 != r.8 { return l.8 < r.8 }
        if l.9 != r.9 { return l.9 < r.9 }
        if l.10 != r.10 { return l.10 < r.10 }
        if l.11 != r.11 { return l.11 < r.11 }
        if l.12 != r.12 { return l.12 < r.12 }
        if l.13 != r.13 { return l.13 < r.13 }
        if l.14 != r.14 { return l.14 < r.14 }
        return l.15 < r.15
    }

    /// Offer one scored candidate.
    mutating func offer(id: UUID, score: Float) {
        guard limit > 0 else { return }
        let candidate = (id: id, score: score)
        if heap.count < limit {
            heap.append(candidate)
            siftUp(from: heap.count - 1)
        } else if Self.outranks(candidate, heap[0]) {
            heap[0] = candidate
            siftDown(from: 0)
        }
    }

    /// The kept candidates, best first. At most `limit` of them, so this sort is
    /// over ≤ 500 elements however large the corpus was.
    func ranked() -> [UUID] {
        heap.sorted(by: Self.outranks).map(\.id)
    }

    /// The heap invariant: a parent is OUTRANKED BY its children, so `heap[0]` is
    /// the weakest kept candidate — the one a new offer has to beat.
    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.outranks(heap[parent], heap[child]) else { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var weakest = parent
            if left < heap.count, Self.outranks(heap[weakest], heap[left]) { weakest = left }
            if right < heap.count, Self.outranks(heap[weakest], heap[right]) { weakest = right }
            guard weakest != parent else { return }
            heap.swapAt(parent, weakest)
            parent = weakest
        }
    }
}

// MARK: - The resident slot

/// The one resident ``EmbeddingCorpus``, and the rules for replacing it.
///
/// **ONE slot, not a dictionary.** A query at a different `(modelVersion,
/// dimensions)` evicts rather than joining, which is what keeps the memory
/// statement — 2 KB × N — a single number instead of a number times however many
/// model versions a mid-backfill library happens to hold. Production issues one
/// pair; a library mid-model-upgrade pays one reload per flip, and the flip is
/// not a thing a user does.
///
/// **The generation guard.** A cold load of 40 MB is slow enough for a write to
/// commit underneath it. Every load reads the generation BEFORE it starts and
/// publishes only if it has not moved, so a corpus assembled from a snapshot
/// older than the last invalidation is thrown away rather than installed. Without
/// it, a fast `upsertEmbedding` racing a slow first query would leave the stale
/// corpus resident with nothing left to clear it.
///
/// **What the guard does NOT close.** `invalidate()` runs immediately after its
/// write commits, not atomically with it, so a load that read the pre-commit
/// snapshot and publishes inside that gap is accepted and then dropped by the
/// invalidation a moment later. A query landing in that window ranks against one
/// vector's previous value. It cannot surface a DELETED asset — the live SQL
/// pre-filter decides membership, never this cache — so the whole exposure is
/// "one result is a moment out of date", which is what an embedding backfill
/// running in the background means anyway.
final class EmbeddingCorpusCache: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var corpus: EmbeddingCorpus?
        var loads = 0
        var hits = 0
    }

    private let state = Mutex(State())

    /// Drop the resident corpus and poison any load already in flight. Called by
    /// the two writers that can change what a corpus holds — `upsertEmbedding`
    /// and the asset delete — and by nothing else.
    func invalidate() {
        state.withLock {
            $0.generation &+= 1
            $0.corpus = nil
        }
    }

    /// The corpus for `(modelVersion, dimensions)`, loading it through `load` on
    /// a miss.
    ///
    /// `load` runs OUTSIDE the lock. It reads the database, and holding a mutex
    /// across a 40 MB read would serialize every other query behind it for the
    /// whole load — including the ones that would have hit.
    func corpus(
        modelVersion: Int,
        dimensions: Int,
        load: () throws -> EmbeddingCorpus
    ) rethrows -> EmbeddingCorpus {
        enum Lookup {
            case hit(EmbeddingCorpus)
            /// A miss, carrying the generation the load must still be publishing under.
            case miss(UInt64)
        }
        let lookup: Lookup = state.withLock { state in
            if let resident = state.corpus,
               resident.modelVersion == modelVersion, resident.dimensions == dimensions {
                state.hits += 1
                return .hit(resident)
            }
            state.loads += 1
            return .miss(state.generation)
        }
        switch lookup {
        case .hit(let resident):
            return resident
        case .miss(let generation):
            let fresh = try load()
            state.withLock { state in
                guard state.generation == generation else { return }
                state.corpus = fresh
            }
            return fresh
        }
    }

    /// What is resident right now — for tests and for the harness's report.
    var resident: EmbeddingCorpus? { state.withLock { $0.corpus } }

    /// Whether anything is resident at all.
    var isLoaded: Bool { state.withLock { $0.corpus != nil } }

    /// How many loads were STARTED, and how many queries were served from memory.
    /// Tests assert on these: "a second query does not reload" and "an upsert
    /// makes the next one reload" are otherwise unobservable. `loads` counts
    /// attempts, so a load that threw still shows.
    var statistics: (loads: Int, hits: Int) { state.withLock { ($0.loads, $0.hits) } }
}
