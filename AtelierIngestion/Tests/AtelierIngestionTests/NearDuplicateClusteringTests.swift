// AtelierIngestion — near-duplicate clustering tests (feature 012, I5)
//
// The grouping is a pure function, so it is pinned here exactly, with hashes
// written by hand at known distances rather than decoded from fixtures. What is
// under test is POLICY, and the policy exists because the action attached to a
// cluster is a delete:
//
//   · the threshold boundary is inclusive, and one bit past it groups nothing;
//   · complete linkage — A~B, B~C, A≁C is TWO clusters, never the chained one;
//   · a group that shrinks below two members stops existing rather than offering
//     its last remaining copy for deletion;
//   · the dHash blind spots (all-zero / all-ones) never form a cluster at all;
//   · the banding optimisation finds every pair a full O(n²) sweep would — the
//     one property whose failure would be silent.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("NearDuplicateClustering (012 I5)")
struct NearDuplicateClusteringTests {

    /// A structured, deliberately NON-degenerate base signature (mixed bits, so it
    /// is neither 0 nor `UInt64.max` and stays clear of the excluded values however
    /// it is perturbed by a few bits).
    private static let base: UInt64 = 0xA5A5_5A5A_0F0F_F0F0

    /// `base` with `count` bits flipped, starting at bit `from` — the whole
    /// distance vocabulary these tests need: `flip(3, from: 0)` is exactly 3 bits
    /// away from `base`, and `flip(3, from: 0)` vs `flip(3, from: 3)` are exactly
    /// 6 apart (disjoint bit ranges).
    private static func flip(_ count: Int, from start: Int = 0, of hash: UInt64 = base) -> UInt64 {
        var result = hash
        for bit in start ..< (start + count) { result ^= (1 as UInt64) << UInt64(bit) }
        return result
    }

    private static func asset(_ hash: UInt64) -> HashedAsset {
        HashedAsset(id: UUID(), hash: hash)
    }

    /// Cluster and return just the member-id lists, which is what the assertions
    /// below are actually about.
    private static func grouped(
        _ hashes: [HashedAsset], within distance: Int = NearDuplicateClustering.defaultDistance
    ) -> [[UUID]] {
        NearDuplicateClustering.clusters(of: hashes, within: distance).map(\.memberIDs)
    }

    // MARK: - The empty and the quiet library

    @Test("an empty library produces no clusters")
    func emptyLibrary() {
        #expect(NearDuplicateClustering.clusters(of: []).isEmpty)
    }

    @Test("a single analyzed image can never be a cluster")
    func singleAsset() {
        #expect(NearDuplicateClustering.clusters(of: [Self.asset(Self.base)]).isEmpty)
    }

    @Test("a library with no near-duplicates produces no clusters")
    func noDuplicates() {
        // Four signatures pairwise far apart (16 disjoint flipped bits each step).
        let hashes = (0 ..< 4).map { step in Self.asset(Self.flip(16, from: step * 16)) }
        #expect(NearDuplicateClustering.clusters(of: hashes).isEmpty)
    }

    // MARK: - The threshold boundary

    @Test("identical hashes group, and the group reports distance 0")
    func identicalHashes() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.base)
        let c = Self.asset(Self.base)
        let clusters = NearDuplicateClustering.clusters(of: [a, b, c])
        #expect(clusters.count == 1)
        #expect(clusters.first?.memberIDs == [a.id, b.id, c.id])
        #expect(clusters.first?.widestDistance == 0)
    }

    /// Every distance from 0 up to the cutoff groups; the cutoff is INCLUSIVE.
    @Test("distances 0…5 are inside the default threshold", arguments: 0 ... 5)
    func insideThreshold(distance: Int) {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(distance))
        let clusters = NearDuplicateClustering.clusters(of: [a, b])
        #expect(clusters.count == 1)
        #expect(clusters.first?.widestDistance == distance)
    }

    /// One bit past the cutoff, and every distance beyond it, groups nothing.
    @Test("distances 6…12 are outside the default threshold", arguments: 6 ... 12)
    func outsideThreshold(distance: Int) {
        let pair = [Self.asset(Self.base), Self.asset(Self.flip(distance))]
        #expect(NearDuplicateClustering.clusters(of: pair).isEmpty)
    }

    @Test("the threshold is a parameter: distance 6 groups at a cutoff of 6")
    func explicitThreshold() {
        let pair = [Self.asset(Self.base), Self.asset(Self.flip(6))]
        #expect(NearDuplicateClustering.clusters(of: pair, within: 5).isEmpty)
        #expect(NearDuplicateClustering.clusters(of: pair, within: 6).count == 1)
    }

    @Test("a cutoff of 0 groups only byte-identical signatures")
    func zeroThreshold() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.base)
        let c = Self.asset(Self.flip(1))
        let clusters = NearDuplicateClustering.clusters(of: [a, b, c], within: 0)
        #expect(clusters.count == 1)
        #expect(clusters.first?.memberIDs == [a.id, b.id])
    }

    // MARK: - Transitivity (the decided case)

    @Test("A~B, B~C, A≁C is TWO clusters — never the chained one")
    func transitivityIsNotAssumed() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(3, from: 0))                 // d(a,b) = 3
        let c = Self.asset(Self.flip(3, from: 3, of: b.hash))     // d(b,c) = 3, d(a,c) = 6
        #expect(PerceptualHash.hammingDistance(a.hash, b.hash) == 3)
        #expect(PerceptualHash.hammingDistance(b.hash, c.hash) == 3)
        #expect(PerceptualHash.hammingDistance(a.hash, c.hash) == 6)

        let clusters = Self.grouped([a, b, c])
        #expect(clusters.count == 2)
        // Complete linkage: both honest pairs are shown, B in both. The chained
        // group [a, b, c] would assert a and c are copies — they are 6 bits apart.
        #expect(clusters.contains([a.id, b.id]))
        #expect(clusters.contains([b.id, c.id]))
        #expect(!clusters.contains([a.id, b.id, c.id]))
    }

    @Test("a chain of near steps never merges into one long cluster")
    func chainingIsRefused() {
        // Five signatures, each 3 bits from the last, so consecutive pairs are
        // inside the threshold and every non-consecutive pair is outside it.
        let chain = (0 ..< 5).map { step in Self.asset(Self.flip(3 * step, from: 0)) }
        let clusters = NearDuplicateClustering.clusters(of: chain)
        // Four consecutive pairs, and nothing wider than a pair.
        #expect(clusters.count == 4)
        #expect(clusters.allSatisfy { $0.members.count == 2 })
        #expect(clusters.allSatisfy { $0.widestDistance == 3 })
    }

    @Test("a genuinely mutual trio IS one cluster")
    func mutualTrioGroups() {
        // Each pair differs by 2 bits: a↔b, b↔c and a↔c are all inside 5.
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(1, from: 0))
        let c = Self.asset(Self.flip(1, from: 1))
        #expect(PerceptualHash.hammingDistance(b.hash, c.hash) == 2)
        let clusters = NearDuplicateClustering.clusters(of: [a, b, c])
        #expect(clusters.count == 1)
        #expect(clusters.first?.memberIDs == [a.id, b.id, c.id])
        #expect(clusters.first?.widestDistance == 2)
    }

    // MARK: - Input conditioning

    @Test("the dHash blind spots never form a cluster", arguments: [UInt64(0), UInt64.max])
    func degenerateHashesExcluded(hash: UInt64) {
        // Four solid images all reduce to the same degenerate signature. Grouping
        // them would propose deleting images that share nothing but flatness.
        let flats = (0 ..< 4).map { _ in Self.asset(hash) }
        #expect(NearDuplicateClustering.clusters(of: flats).isEmpty)
    }

    @Test("a degenerate hash is dropped without taking real clusters with it")
    func degenerateAlongsideRealDuplicates() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(2))
        let flat = Self.asset(0)
        let clusters = Self.grouped([a, flat, b])
        #expect(clusters == [[a.id, b.id]])
    }

    @Test("a repeated asset id keeps its first occurrence only")
    func duplicateIDsCollapse() {
        let id = UUID()
        let first = HashedAsset(id: id, hash: Self.base)
        let second = HashedAsset(id: id, hash: Self.flip(2))
        #expect(NearDuplicateClustering.clusters(of: [first, second]).isEmpty)
        #expect(NearDuplicateClustering.usable([first, second]) == [first])
    }

    // MARK: - Ordering and determinism

    @Test("members keep the caller's input order — the oldest copy leads")
    func inputOrderPreserved() {
        let oldest = Self.asset(Self.base)
        let middle = Self.asset(Self.flip(1))
        let newest = Self.asset(Self.flip(2))
        #expect(Self.grouped([oldest, middle, newest]) == [[oldest.id, middle.id, newest.id]])
        #expect(Self.grouped([newest, middle, oldest]) == [[newest.id, middle.id, oldest.id]])
    }

    @Test("the same input always produces the same clusters")
    func deterministic() {
        var random = SeededRandom(seed: 0x5EED)
        let hashes = (0 ..< 200).map { _ in Self.asset(random.next()) }
            + (0 ..< 40).map { _ in Self.asset(Self.flip(Int(random.next() % 5))) }
        let first = Self.grouped(hashes)
        for _ in 0 ..< 3 { #expect(Self.grouped(hashes) == first) }
    }

    // MARK: - Banding must not lose a pair

    @Test("banding finds every pair a full O(n²) sweep would", arguments: [0, 1, 3, 5, 8])
    func bandingMatchesBruteForce(threshold: Int) {
        var random = SeededRandom(seed: 0xD00D)
        // A mixed population: unrelated signatures plus deliberate near-copies of a
        // handful of them, so there are real pairs to find at every threshold.
        var hashes = (0 ..< 300).map { _ in Self.asset(random.next()) }
        for index in stride(from: 0, to: 60, by: 3) {
            let perturbed = Self.flip(
                Int(random.next() % 9), from: Int(random.next() % 40), of: hashes[index].hash)
            hashes.append(Self.asset(perturbed))
        }

        let clusters = NearDuplicateClustering.clusters(of: hashes, within: threshold)
        // Every emitted cluster is internally complete — no chaining slipped in.
        for cluster in clusters {
            for (offset, left) in cluster.members.enumerated() {
                for right in cluster.members[(offset + 1)...] {
                    #expect(PerceptualHash.hammingDistance(left.hash, right.hash) <= threshold)
                }
            }
        }
        // And every true pair the brute-force sweep finds is shown together
        // somewhere — the property whose failure banding would hide.
        let usable = NearDuplicateClustering.usable(hashes)
        for (offset, left) in usable.enumerated() {
            for right in usable[(offset + 1)...]
            where PerceptualHash.hammingDistance(left.hash, right.hash) <= threshold {
                let shown = clusters.contains {
                    $0.memberIDs.contains(left.id) && $0.memberIDs.contains(right.id)
                }
                #expect(shown, "pair at distance \(PerceptualHash.hammingDistance(left.hash, right.hash)) was not shown")
            }
        }
    }

    @Test("bands are disjoint, cover all 64 bits, and number threshold + 1",
          arguments: [0, 1, 5, 10, 63, 64, 100])
    func bandLayout(threshold: Int) {
        let bands = NearDuplicateClustering.bandRanges(forThreshold: threshold)
        #expect(bands.count == min(threshold + 1, PerceptualHash.bitCount))
        #expect(bands.reduce(0) { $0 + $1.width } == PerceptualHash.bitCount)
        #expect(bands.allSatisfy { $0.width >= 1 })
        var expectedOffset = 0
        for band in bands {
            #expect(band.offset == expectedOffset)
            expectedOffset += band.width
        }
    }

    // MARK: - Shrinking a cluster

    @Test("removing a member leaves the rest of the cluster intact")
    func reconcileShrinksCluster() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(1))
        let c = Self.asset(Self.flip(2))
        let clusters = NearDuplicateClustering.clusters(of: [a, b, c])
        let after = NearDuplicateClustering.reconciled(clusters, removing: [b.id])
        #expect(after.count == 1)
        #expect(after.first?.memberIDs == [a.id, c.id])
        // Recomputed from what remains, not carried over from the wider group.
        #expect(after.first?.widestDistance == PerceptualHash.hammingDistance(a.hash, c.hash))
    }

    @Test("a cluster down to one member stops existing — its last copy is never offered")
    func reconcileDropsLastMember() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(1))
        let clusters = NearDuplicateClustering.clusters(of: [a, b])
        #expect(clusters.count == 1)
        #expect(NearDuplicateClustering.reconciled(clusters, removing: [a.id]).isEmpty)
        #expect(NearDuplicateClustering.reconciled(clusters, removing: [a.id, b.id]).isEmpty)
    }

    @Test("deleting a shared member empties both clusters it appeared in")
    func reconcileAcrossOverlappingClusters() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(3, from: 0))
        let c = Self.asset(Self.flip(3, from: 3, of: Self.flip(3, from: 0)))
        let clusters = NearDuplicateClustering.clusters(of: [a, b, c])
        #expect(clusters.count == 2)
        // b is in both; removing it leaves [a] and [c], neither of them a cluster.
        #expect(NearDuplicateClustering.reconciled(clusters, removing: [b.id]).isEmpty)
        // Removing a leaves [b, c] alone — c's copy is still reviewable.
        let afterA = NearDuplicateClustering.reconciled(clusters, removing: [a.id])
        #expect(afterA.map(\.memberIDs) == [[b.id, c.id]])
    }

    @Test("removing nothing changes nothing")
    func reconcileNoOp() {
        let clusters = NearDuplicateClustering.clusters(
            of: [Self.asset(Self.base), Self.asset(Self.flip(1))])
        #expect(NearDuplicateClustering.reconciled(clusters, removing: []) == clusters)
        #expect(NearDuplicateClustering.reconciled(clusters, removing: [UUID()]) == clusters)
    }

    @Test("retaining keeps only clusters whose every member is still live")
    func retainLiveMembers() {
        let a = Self.asset(Self.base)
        let b = Self.asset(Self.flip(1))
        let c = Self.asset(Self.flip(2))
        let clusters = NearDuplicateClustering.clusters(of: [a, b, c])
        #expect(NearDuplicateClustering.retaining(clusters, liveIDs: [a.id, b.id, c.id]) == clusters)
        #expect(NearDuplicateClustering.retaining(clusters, liveIDs: [a.id, c.id])
            .map(\.memberIDs) == [[a.id, c.id]])
        #expect(NearDuplicateClustering.retaining(clusters, liveIDs: [a.id]).isEmpty)
        #expect(NearDuplicateClustering.retaining(clusters, liveIDs: []).isEmpty)
    }
}

/// A tiny reproducible generator — the clustering is deterministic, so its tests
/// must be too (a flaky grouping failure would be unfixable).
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    /// xorshift64*, enough spread for hash-shaped test data.
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
