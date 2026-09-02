// AtelierCore — the resident semantic corpus, its selector and its slot (099 · P0b).
//
// Everything here is pure: no database, no services. The database-level
// behaviour — that the cached query returns what the un-cached one returned, and
// that both writers invalidate — is `ServicesSemanticCorpusTests`.
//
// The load-bearing assertion in this file is that ``TopKSelector`` and a FULL
// SORT agree, including on ties. That is the one thing the partial selection can
// get subtly wrong and no timing number would ever reveal.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Embedding corpus: matrix, selection, slot (099 · P0b)")
struct EmbeddingCorpusTests {

    // MARK: - Helpers

    /// A seeded xorshift, so a failing trial is one a reader can re-run. The
    /// suite compares two orderings over hundreds of cases; drawing them from
    /// `SystemRandomNumberGenerator` would produce a bug report nobody could
    /// reproduce.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        /// A uuid drawn from this generator — ids have to be deterministic too,
        /// because the tiebreak is an assertion ABOUT ids.
        mutating func uuid() -> UUID {
            var bytes: [UInt8] = []
            for _ in 0..<2 {
                var word = next()
                withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
            }
            return EmbeddingCorpusTests.uuid(bytes)
        }
    }

    /// A uuid from exactly 16 bytes.
    private static func uuid(_ b: [UInt8]) -> UUID {
        UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func corpus(
        modelVersion: Int = 1, dimensions: Int, rows: [(UUID, [Float])]
    ) -> EmbeddingCorpus {
        var builder = EmbeddingCorpusBuilder(
            modelVersion: modelVersion, dimensions: dimensions, expectedRows: rows.count)
        for (id, vector) in rows {
            builder.append(key: id.uuidString.lowercased(), vector: AssetEmbedding.encode(vector))
        }
        return builder.finish()
    }

    private func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    // MARK: - The uuid tiebreak

    /// The tiebreak compares raw bytes so it does not allocate a `String` on
    /// every exact score tie in a 20,000-row scan. That is only sound if the two
    /// orders are the same order — asserted here rather than reasoned about in a
    /// comment, and over pairs that share fifteen bytes so the comparison is
    /// actually driven past the first one.
    @Test("byte order IS uuidString order")
    func precedesMatchesStringOrder() {
        var rng = Seeded(state: 0x5EED_1234)
        for _ in 0..<500 {
            let a = rng.uuid(), b = rng.uuid()
            #expect(TopKSelector.precedes(a, b) == (a.uuidString < b.uuidString))
            #expect(TopKSelector.precedes(b, a) == (b.uuidString < a.uuidString))

            // A pair differing only in the LAST byte.
            var bytes: [UInt8] = []
            for _ in 0..<2 {
                var word = rng.next()
                withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
            }
            let shared = Self.uuid(bytes)
            bytes[15] = bytes[15] &+ 1
            let sibling = Self.uuid(bytes)
            #expect(
                TopKSelector.precedes(shared, sibling)
                    == (shared.uuidString < sibling.uuidString))
        }
    }

    @Test("a uuid does not precede itself")
    func precedesIsIrreflexive() {
        let id = UUID()
        #expect(!TopKSelector.precedes(id, id))
    }

    // MARK: - The selector

    /// **The load-bearing test of this file.** The partial selection must produce
    /// exactly what the full sort it replaced produced — same members, same order
    /// — at every k, over data with deliberate ties.
    @Test("the bounded heap agrees with a full sort, at every k, ties included")
    func selectorMatchesFullSort() {
        var rng = Seeded(state: 0xC0FF_EE01)
        for trial in 0..<40 {
            let n = 1 + trial
            // Scores drawn from a SMALL set so exact ties are common — the whole
            // point. A continuous distribution would tie roughly never.
            let items: [(id: UUID, score: Float)] = (0..<n).map { _ in
                (rng.uuid(), Float(Int.random(in: 0...4, using: &rng)))
            }
            let fullSort = items
                .sorted {
                    $0.score != $1.score ? $0.score > $1.score
                        : $0.id.uuidString < $1.id.uuidString
                }
                .map(\.id)

            for k in [1, 2, 3, 5, n, n + 7] {
                var selector = TopKSelector(limit: k)
                for item in items { selector.offer(id: item.id, score: item.score) }
                #expect(selector.ranked() == Array(fullSort.prefix(k)), "n=\(n) k=\(k)")
            }
        }
    }

    @Test("limit 0 keeps nothing")
    func selectorAtZero() {
        var selector = TopKSelector(limit: 0)
        for _ in 0..<10 { selector.offer(id: UUID(), score: 1) }
        #expect(selector.ranked().isEmpty)
    }

    @Test("a negative limit is treated as zero, not as a crash")
    func selectorAtNegative() {
        var selector = TopKSelector(limit: -3)
        selector.offer(id: UUID(), score: 1)
        #expect(selector.ranked().isEmpty)
    }

    @Test("fewer offers than the limit returns them all, still ranked")
    func selectorUnderfilled() {
        let a = UUID(), b = UUID()
        var selector = TopKSelector(limit: 50)
        selector.offer(id: a, score: 0.1)
        selector.offer(id: b, score: 0.9)
        #expect(selector.ranked() == [b, a])
    }

    /// Every score identical: the answer is the k lowest ids, in id order. This
    /// is the case a bounded heap gets wrong if the tiebreak is carried in the
    /// final sort but not in the EVICTION comparison.
    @Test("an all-tied field selects the k lowest ids in id order")
    func selectorAllTied() {
        var rng = Seeded(state: 0xA11_71ED)
        let ids = (0..<20).map { _ in rng.uuid() }
        var selector = TopKSelector(limit: 5)
        for id in ids { selector.offer(id: id, score: 0.5) }
        let expected = Array(ids.sorted { $0.uuidString < $1.uuidString }.prefix(5))
        #expect(selector.ranked() == expected)
    }

    // MARK: - The builder

    @Test("the matrix is one contiguous row-major allocation")
    func matrixIsRowMajor() {
        let a = UUID(), b = UUID()
        let c = corpus(dimensions: 3, rows: [(a, [1, 2, 3]), (b, [4, 5, 6])])
        #expect(c.count == 2)
        #expect(c.matrix == [1, 2, 3, 4, 5, 6])
        #expect(c.ids == [a, b])
        #expect(c.rowIndex[key(a)] == 0)
        #expect(c.rowIndex[key(b)] == 1)
    }

    /// A vector of the wrong length is SKIPPED, not thrown — `append`'s doc
    /// comment says why (derived data a re-embed rewrites; one bad row must not
    /// take the whole library's meaning search down). Skipping it must also leave
    /// the rows AFTER it correctly indexed, which is the half a careless
    /// `continue` gets wrong.
    @Test("a wrong-width blob is skipped, counted, and does not shift the rows after it")
    func builderSkipsWrongWidth() {
        let a = UUID(), bad = UUID(), b = UUID()
        var builder = EmbeddingCorpusBuilder(modelVersion: 1, dimensions: 3)
        builder.append(key: key(a), vector: AssetEmbedding.encode([1, 0, 0]))
        builder.append(key: key(bad), vector: AssetEmbedding.encode([1, 0]))       // too short
        builder.append(key: key(b), vector: AssetEmbedding.encode([0, 1, 0]))
        let skipped = builder.skipped
        let c = builder.finish()

        #expect(skipped == 1)
        #expect(c.count == 2)
        #expect(c.ids == [a, b])
        #expect(c.rowIndex[key(bad)] == nil)
        #expect(c.rowIndex[key(b)] == 1)
        #expect(c.matrix == [1, 0, 0, 0, 1, 0])
    }

    @Test("a blob that is too LONG is skipped too — exactness, not a prefix")
    func builderSkipsOverlongBlob() {
        var builder = EmbeddingCorpusBuilder(modelVersion: 1, dimensions: 3)
        builder.append(key: key(UUID()), vector: AssetEmbedding.encode([1, 0, 0, 9]))
        let skipped = builder.skipped
        #expect(builder.finish().count == 0)
        #expect(skipped == 1)
    }

    @Test("an empty blob is skipped")
    func builderSkipsEmptyBlob() {
        var builder = EmbeddingCorpusBuilder(modelVersion: 1, dimensions: 3)
        builder.append(key: key(UUID()), vector: Data())
        #expect(builder.finish().count == 0)
    }

    @Test("a key that is not a uuid is skipped")
    func builderSkipsNonUUIDKey() {
        var builder = EmbeddingCorpusBuilder(modelVersion: 1, dimensions: 2)
        #expect(builder.append(key: "not-a-uuid", vector: AssetEmbedding.encode([1, 0])) == false)
        let skipped = builder.skipped
        #expect(builder.finish().count == 0)
        #expect(skipped == 1)
    }

    /// `asset_id` is the table's primary key so this cannot arise from SQLite,
    /// but the builder is a pure type and a second row under one key would
    /// otherwise leave `rowIndex` pointing at the LAST matrix row while `ids`
    /// held both — a silent mis-scoring.
    @Test("a duplicate key keeps the first row and skips the second")
    func builderSkipsDuplicateKey() {
        let a = UUID()
        var builder = EmbeddingCorpusBuilder(modelVersion: 1, dimensions: 2)
        builder.append(key: key(a), vector: AssetEmbedding.encode([1, 0]))
        #expect(builder.append(key: key(a), vector: AssetEmbedding.encode([0, 1])) == false)
        let c = builder.finish()
        #expect(c.count == 1)
        #expect(c.matrix == [1, 0])
    }

    @Test("an empty corpus is valid and answers nothing")
    func emptyCorpus() {
        let c = corpus(dimensions: 512, rows: [])
        #expect(c.count == 0)
        #expect(c.matrix.isEmpty)
        #expect(c.topMatches(
            query: [Float](repeating: 1, count: 512),
            candidateKeys: [key(UUID())], limit: 10).isEmpty)
    }

    @Test("the stated memory cost is 2 KB per 512-float vector")
    func memoryCostIsTwoKilobytesPerVector() {
        let rows = (0..<10).map { i in (UUID(), (0..<512).map { Float($0 &+ i) }) }
        let c = corpus(dimensions: 512, rows: rows)
        #expect(c.matrix.count == 10 * 512)
        #expect(c.matrix.count * MemoryLayout<Float>.stride == 10 * 2048)
        #expect(c.approximateBytes > 10 * 2048)
    }

    // MARK: - Scoring

    @Test("topMatches ranks by dot product, nearest first")
    func ranksByDotProduct() {
        let near = UUID(), mid = UUID(), far = UUID()
        let c = corpus(dimensions: 3, rows: [
            (far, [0, 1, 0]), (near, [1, 0, 0]), (mid, [0.7071, 0.7071, 0]),
        ])
        let keys = [far, near, mid].map(key)
        #expect(c.topMatches(query: [1, 0, 0], candidateKeys: keys, limit: 10) == [near, mid, far])
    }

    @Test("a candidate key the corpus does not hold is skipped, not scored")
    func unknownCandidateIsSkipped() {
        let a = UUID(), ghost = UUID()
        let c = corpus(dimensions: 3, rows: [(a, [1, 0, 0])])
        #expect(c.topMatches(
            query: [1, 0, 0], candidateKeys: [key(ghost), key(a)], limit: 10) == [a])
    }

    /// The scope is an INTERSECTION: a vector the corpus holds but the caller did
    /// not offer as a candidate is not a result. This is the property that makes
    /// a stale corpus structurally unable to surface a deleted asset.
    @Test("a resident vector outside the candidate set never ranks")
    func residentButOutOfScope() {
        let inScope = UUID(), outOfScope = UUID()
        let c = corpus(dimensions: 3, rows: [
            (inScope, [0, 1, 0]),          // far from the query
            (outOfScope, [1, 0, 0]),       // a perfect match, and excluded anyway
        ])
        #expect(c.topMatches(
            query: [1, 0, 0], candidateKeys: [key(inScope)], limit: 10) == [inScope])
    }

    @Test("a query of the wrong width ranks nothing")
    func wrongWidthQuery() {
        let a = UUID()
        let c = corpus(dimensions: 3, rows: [(a, [1, 0, 0])])
        #expect(c.topMatches(query: [1, 0], candidateKeys: [key(a)], limit: 10).isEmpty)
        #expect(c.topMatches(query: [], candidateKeys: [key(a)], limit: 10).isEmpty)
    }

    @Test("limit 0 and an empty candidate set both rank nothing")
    func degenerateInputs() {
        let a = UUID()
        let c = corpus(dimensions: 3, rows: [(a, [1, 0, 0])])
        #expect(c.topMatches(query: [1, 0, 0], candidateKeys: [key(a)], limit: 0).isEmpty)
        #expect(c.topMatches(query: [1, 0, 0], candidateKeys: [], limit: 10).isEmpty)
    }

    @Test("a corpus smaller than the limit returns everything it has")
    func smallerThanLimit() {
        let a = UUID(), b = UUID()
        let c = corpus(dimensions: 2, rows: [(a, [1, 0]), (b, [0.5, 0.5])])
        #expect(c.topMatches(
            query: [1, 0], candidateKeys: [a, b].map(key), limit: 500) == [a, b])
    }

    // MARK: - The resident slot

    @Test("a hit does not reload; the second query is served from memory")
    func hitDoesNotReload() {
        let cache = EmbeddingCorpusCache()
        let built = corpus(dimensions: 2, rows: [(UUID(), [1, 0])])
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { built }
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { built }
        #expect(cache.statistics.loads == 1)
        #expect(cache.statistics.hits == 1)
    }

    @Test("invalidate drops the corpus and the next query reloads")
    func invalidateForcesReload() {
        let cache = EmbeddingCorpusCache()
        let built = corpus(dimensions: 2, rows: [(UUID(), [1, 0])])
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { built }
        #expect(cache.isLoaded)
        cache.invalidate()
        #expect(!cache.isLoaded)
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { built }
        #expect(cache.statistics.loads == 2)
        #expect(cache.statistics.hits == 0)
    }

    /// One slot, so a query at another model version EVICTS rather than joining —
    /// the reason the memory statement is one number and not one per version.
    @Test("another model version evicts rather than sharing the slot")
    func otherModelVersionEvicts() {
        let cache = EmbeddingCorpusCache()
        let v1 = corpus(modelVersion: 1, dimensions: 2, rows: [(UUID(), [1, 0])])
        let v2 = corpus(
            modelVersion: 2, dimensions: 2, rows: [(UUID(), [0, 1]), (UUID(), [1, 1])])
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { v1 }
        #expect(cache.corpus(modelVersion: 2, dimensions: 2) { v2 }.count == 2)
        #expect(cache.resident?.modelVersion == 2)
        // …and back again: the v1 corpus is gone, so it reloads.
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { v1 }
        #expect(cache.statistics.loads == 3)
        #expect(cache.statistics.hits == 0)
    }

    @Test("a different vector width is a different corpus")
    func otherWidthEvicts() {
        let cache = EmbeddingCorpusCache()
        let narrow = corpus(dimensions: 2, rows: [(UUID(), [1, 0])])
        let wide = corpus(dimensions: 3, rows: [(UUID(), [1, 0, 0])])
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { narrow }
        _ = cache.corpus(modelVersion: 1, dimensions: 3) { wide }
        #expect(cache.resident?.dimensions == 3)
        #expect(cache.statistics.loads == 2)
    }

    /// The generation guard. A 40 MB load is slow enough for a write to commit
    /// underneath it; the corpus assembled from the older snapshot must be thrown
    /// away rather than installed, because nothing would ever clear it again.
    @Test("a load that raced an invalidation is used once and never published")
    func racingLoadIsNotPublished() {
        let cache = EmbeddingCorpusCache()
        let stale = corpus(dimensions: 2, rows: [(UUID(), [1, 0])])
        let served = cache.corpus(modelVersion: 1, dimensions: 2) {
            cache.invalidate()          // a writer commits mid-load
            return stale
        }
        // The caller still gets a usable answer for THIS query…
        #expect(served.count == 1)
        // …but nothing is resident, so the next query reads the new truth.
        #expect(!cache.isLoaded)
        #expect(cache.statistics.loads == 1)
    }

    @Test("a load that did not race is published")
    func quietLoadIsPublished() {
        let cache = EmbeddingCorpusCache()
        let built = corpus(dimensions: 2, rows: [(UUID(), [1, 0])])
        _ = cache.corpus(modelVersion: 1, dimensions: 2) { built }
        #expect(cache.isLoaded)
    }

    @Test("a load that throws leaves the slot empty and propagates")
    func throwingLoadIsNotPublished() {
        struct Boom: Error {}
        let cache = EmbeddingCorpusCache()
        #expect(throws: Boom.self) {
            _ = try cache.corpus(modelVersion: 1, dimensions: 2) { throw Boom() }
        }
        #expect(!cache.isLoaded)
    }

    // MARK: - The bulk decoder

    /// The bulk half of the codec must agree lane-for-lane with the public
    /// per-element one — it is a `memcpy` standing in for arithmetic, and the
    /// only thing that makes that legitimate is that the two produce the same
    /// floats.
    @Test("copyVector agrees with vectorFloats, and writes only its own window")
    func copyVectorMatchesCodec() {
        let vector: [Float] = [1.5, -2.25, 0, 3.75, -0.0, .infinity]
        let data = AssetEmbedding.encode(vector)
        var out = [Float](repeating: 99, count: vector.count + 2)
        out.withUnsafeMutableBufferPointer { buffer in
            AssetEmbedding.copyVector(data, into: UnsafeMutableBufferPointer(
                rebasing: buffer[1..<(vector.count + 1)]))
        }
        #expect(Array(out[1...vector.count]) == AssetEmbedding.vectorFloats(data))
        // The neighbours either side are untouched — the row window is exact.
        #expect(out.first == 99)
        #expect(out.last == 99)
    }

    @Test("copyVector on empty data writes nothing")
    func copyVectorEmpty() {
        var out: [Float] = [7]
        out.withUnsafeMutableBufferPointer { buffer in
            AssetEmbedding.copyVector(Data(), into: buffer)
        }
        #expect(out == [7])
    }

    /// A 512-wide round trip through the builder, because the production width is
    /// the one the `memcpy` actually runs at and a 4-lane test would not notice a
    /// stride mistake.
    @Test("a 512-wide row survives the matrix round trip lane for lane")
    func fullWidthRoundTrip() {
        let a = UUID(), b = UUID()
        let first = (0..<512).map { Float($0) * 0.125 }
        let second = (0..<512).map { Float(-$0) * 0.25 }
        let c = corpus(dimensions: 512, rows: [(a, first), (b, second)])
        #expect(Array(c.matrix[0..<512]) == first)
        #expect(Array(c.matrix[512..<1024]) == second)
        #expect(c.matrix.count == 1024)
    }
}
