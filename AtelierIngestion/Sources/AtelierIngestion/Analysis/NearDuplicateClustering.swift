// AtelierIngestion — near-duplicate clustering (feature 012, I5)
//
// The grouping half of the "Duplicates" review surface: perceptual hashes in,
// review clusters out. A PURE function — no database, no UI, no Vision, no
// CoreGraphics — so every rule below is table-testable with hand-written hashes.
//
// The surface this feeds is REVIEW-ONLY: it never merges and never deletes on its
// own. That single fact drives every judgement call here, because the only action
// a cluster offers is destructive and the user is trusting the grouping. So the
// bias throughout is toward proposing LESS: a duplicate we fail to group costs the
// user nothing (the surface simply stays quiet about it, and the pair resurfaces
// on a later pass), while a wrongly-grouped pair invites deleting an image that
// was never a copy. False negatives are free; false positives are the failure this
// feature must not have.
//
// THE THREE RULES
//
//  1. **Threshold ``defaultDistance`` = 5 of 64 bits.** See its doc comment for the
//     arithmetic; the short version is that 5 absorbs re-encoding / resizing (the
//     gap dHash exists to close) while the chance of two UNRELATED images landing
//     that close is ~4.6e-13 per pair.
//
//  2. **Complete linkage, never single linkage.** A group is emitted only when
//     EVERY pair inside it is within the threshold. Single-linkage (transitive
//     closure) would chain — A near B, B near C, C near D — and walk a cluster
//     arbitrarily far from where it started, which is precisely how a review
//     surface ends up proposing that you delete an unrelated image. The
//     consequence is spelled out in ``clusters(of:within:)``: A~B, B~C, A≁C is
//     TWO clusters, not one, and B is shown in both.
//
//  3. **Degenerate hashes are excluded outright.** dHash is flat-blind and
//     hue-blind (``PerceptualHash``'s KNOWN LIMITATION note): every solid or
//     smoothly-monotone image reduces to hash 0, and its mirror to `UInt64.max`.
//     Those two values are not evidence of similarity — they are the absence of
//     evidence — and grouping on them would collect every flat image in the
//     library into one enormous "duplicate" cluster. They are dropped before
//     clustering. Distinguishing genuinely-identical flats needs the colour
//     signature, which is deliberately out of scope for I5.
//
// COST. Comparing every pair is O(n²) — a 100k-image library is ~5e9 comparisons,
// which is not a thing to do behind a sheet. Candidate pairs are found by BANDING
// (multi-index hashing) instead: split the 64 bits into `threshold + 1` disjoint
// bands and bucket by each. Two hashes within `threshold` bits differ in at most
// `threshold` positions, so by the pigeonhole principle at least one of the
// `threshold + 1` bands must match EXACTLY — bucketing therefore cannot miss a
// true pair, only propose extra ones, and every proposal is verified with a real
// Hamming distance before it counts. Cost then scales with the number of
// near-duplicate PAIRS, which in a curated library is small by definition.

import Foundation

/// One asset's perceptual signature — the whole input this module needs.
///
/// Deliberately not an `Asset`: clustering has no business knowing about blobs,
/// sources, or collections, and keeping the input this narrow is what lets the
/// tests build a library out of literals.
public struct HashedAsset: Sendable, Equatable, Hashable, Identifiable {
    /// The asset this hash belongs to.
    public let id: UUID
    /// Its 64-bit ``PerceptualHash`` signature (unsigned — the storage layer owns
    /// the `Int64` bit-cast).
    public let hash: UInt64

    public init(id: UUID, hash: UInt64) {
        self.id = id
        self.hash = hash
    }
}

/// A group of assets proposed as near-identical — one row of the review surface.
///
/// Always at least ``NearDuplicateClustering/minimumSize`` members: a group of one
/// has nothing to compare and nothing to safely delete, so it is not a cluster at
/// all. `members` are in the caller's input order, so whatever order the caller
/// read them in (the app reads oldest-first) is the order the user sees, and the
/// first member reads as "the one you already had".
public struct NearDuplicateCluster: Sendable, Equatable, Hashable, Identifiable {
    /// The grouped assets, in input order. Count ≥ 2, and every pair within the
    /// threshold the cluster was built with (complete linkage).
    public let members: [HashedAsset]
    /// The largest Hamming distance between any two members — how loose this
    /// particular group is. `0` means every member has an identical signature.
    public let widestDistance: Int

    /// Identity is the member id list, which is also the de-duplication key: two
    /// clusters over the same assets are the same cluster. A single member's id
    /// would NOT do — under complete linkage one asset can legitimately appear in
    /// two different clusters.
    public var id: [UUID] { members.map(\.id) }

    /// The grouped asset ids, in input order.
    public var memberIDs: [UUID] { members.map(\.id) }

    public init(members: [HashedAsset], widestDistance: Int) {
        self.members = members
        self.widestDistance = widestDistance
    }
}

/// Groups perceptual hashes into near-duplicate review clusters (012 · I5).
///
/// A stateless namespace of pure functions, matching ``PerceptualHash``.
public enum NearDuplicateClustering {

    /// The default Hamming-distance cutoff: two hashes are near-duplicates when at
    /// most **5 of the 64** gradient bits differ.
    ///
    /// Why 5 and not the ≤10 that ``PerceptualHash`` names as the "usual"
    /// near-duplicate cutoff: the usual cutoff is tuned for a *browse* feature,
    /// where an over-eager match costs a wasted glance. Here the action attached to
    /// a group is a DELETE, so the two error directions are not remotely
    /// symmetric.
    ///
    ///  • **Loose enough.** A re-encode, a resize, a quality-drop re-save — the
    ///    exact cases exact-hash dedup misses (012 §Current state) — move a dHash
    ///    by 0–4 bits, because the hash compares LUMINANCE GRADIENTS of a 9×8
    ///    reduction and those survive resampling. 5 covers that band with a bit to
    ///    spare.
    ///  • **Tight enough.** Of the 2^64 signatures, only
    ///    `Σ C(64,i) for i ≤ 5` ≈ 8.4e6 lie within 5 bits of any given one — about
    ///    4.6e-13 of the space. Even a 100k-image library (5e9 pairs) expects
    ///    ~0.002 accidental pairings. At 10 bits that figure is ~55 — dozens of
    ///    unrelated images offered up for deletion.
    ///
    /// It is a parameter of ``clusters(of:within:)``, not a constant baked into the
    /// algorithm, so it can be re-tuned against measured library data later without
    /// touching the grouping logic.
    public static let defaultDistance = 5

    /// The smallest group worth showing. Two, because the surface's whole purpose
    /// is COMPARISON, and because a one-member "cluster" would offer a delete that
    /// removes the only remaining copy — the one outcome this feature must never
    /// produce quietly. A cluster that shrinks to a single member is dropped, not
    /// shown with a disabled button (see ``reconciled(_:removing:)``).
    public static let minimumSize = 2

    /// Hashes carrying no structure, and therefore no evidence of similarity: an
    /// all-zero signature (every solid image, and every smoothly left-to-right
    /// brightening one) and its all-ones mirror. See the file header, rule 3.
    static let degenerateHashes: Set<UInt64> = [0, UInt64.max]

    // MARK: - Clustering

    /// Group `hashes` into near-duplicate clusters, complete-linkage, within
    /// `distance` Hamming bits.
    ///
    /// - Parameters:
    ///   - hashes: every analyzed asset's signature. Order is meaningful: it is
    ///     preserved inside each cluster and decides cluster order. Repeated ids
    ///     keep their FIRST occurrence.
    ///   - distance: the cutoff, clamped to `0...64`. Defaults to
    ///     ``defaultDistance``.
    /// - Returns: clusters of ≥ ``minimumSize`` members, each internally complete
    ///   (every pair within `distance`), ordered by the input position of the pair
    ///   that seeded them. An empty input, an input with no near pairs, or an input
    ///   of only degenerate hashes all return `[]`.
    ///
    /// **Transitivity — the decided case.** Given A~B and B~C but A≁C, this returns
    /// **two clusters**, `[A, B]` and `[B, C]`, with B a member of both. It does
    /// NOT return the single chained group `[A, B, C]`. Merging them would assert
    /// that A and C are copies of each other, which the hashes say they are not,
    /// and would put an unrelated image one click from deletion. Showing the two
    /// honest pairs instead lets the user resolve whichever they agree with; the
    /// other simply re-appears on the next scan, minus whatever they deleted.
    /// Overlap is safe for the destructive action because a cluster is dropped the
    /// moment it falls below ``minimumSize`` — deleting B empties both groups
    /// rather than leaving either offering its last copy.
    ///
    /// Not every maximal complete group is enumerated (that problem is exponential
    /// in the worst case). Once a pair has been covered by an emitted cluster it is
    /// not re-grown from, so the result is a deterministic, stable SELECTION of
    /// review groups rather than an exhaustive one.
    public static func clusters(
        of hashes: [HashedAsset], within distance: Int = defaultDistance
    ) -> [NearDuplicateCluster] {
        let threshold = min(max(distance, 0), PerceptualHash.bitCount)
        let candidates = usable(hashes)
        guard candidates.count >= minimumSize else { return [] }

        let neighbours = neighbourLists(of: candidates, within: threshold)

        var emitted: [NearDuplicateCluster] = []
        var emittedIndices: [Set<Int>] = []

        for seed in candidates.indices {
            for other in neighbours[seed] where other > seed {
                // Skip a pair an already-emitted cluster covers: re-growing from it
                // yields the same group or a redundant subset of one.
                if emittedIndices.contains(where: { $0.contains(seed) && $0.contains(other) }) {
                    continue
                }
                let group = grow(
                    from: seed, and: other, candidates: candidates,
                    neighbours: neighbours, threshold: threshold)
                let indices = Set(group)
                guard !emittedIndices.contains(indices) else { continue }
                emittedIndices.append(indices)
                emitted.append(NearDuplicateCluster(
                    members: group.map { candidates[$0] },
                    widestDistance: widest(group, in: candidates)))
            }
        }
        return emitted
    }

    /// Drop `removedIDs` from every cluster and discard any group left with fewer
    /// than ``minimumSize`` members — the rule that keeps a shrinking cluster from
    /// ever offering its last copy for deletion.
    ///
    /// Pure, so the surface's shrink behaviour is tested without a database. Order
    /// is preserved; ``NearDuplicateCluster/widestDistance`` is recomputed from what
    /// actually remains rather than carried over stale. An empty `removedIDs`
    /// returns the clusters unchanged.
    public static func reconciled(
        _ clusters: [NearDuplicateCluster], removing removedIDs: Set<UUID>
    ) -> [NearDuplicateCluster] {
        guard !removedIDs.isEmpty else { return clusters }
        return clusters.compactMap { cluster in
            let survivors = cluster.members.filter { !removedIDs.contains($0.id) }
            guard survivors.count >= minimumSize else { return nil }
            guard survivors.count != cluster.members.count else { return cluster }
            return NearDuplicateCluster(
                members: survivors,
                widestDistance: widest(Array(survivors.indices), in: survivors))
        }
    }

    /// Keep only the clusters whose every member is still present in `liveIDs` —
    /// the complement of ``reconciled(_:removing:)`` for the case where the caller
    /// knows what SURVIVED rather than what went.
    ///
    /// Used at the seam where a cluster is about to be acted on: an asset deleted
    /// out from under the surface (another window, an undo, a restore) must never
    /// be offered as a delete target.
    public static func retaining(
        _ clusters: [NearDuplicateCluster], liveIDs: Set<UUID>
    ) -> [NearDuplicateCluster] {
        let removed = Set(clusters.flatMap(\.memberIDs)).subtracting(liveIDs)
        return reconciled(clusters, removing: removed)
    }

    // MARK: - Input conditioning

    /// The hashes worth clustering: first occurrence of each id, degenerate
    /// signatures dropped (file header, rule 3).
    static func usable(_ hashes: [HashedAsset]) -> [HashedAsset] {
        var seen: Set<UUID> = []
        return hashes.filter { candidate in
            guard !degenerateHashes.contains(candidate.hash) else { return false }
            return seen.insert(candidate.id).inserted
        }
    }

    // MARK: - Candidate pairs (banding)

    /// For each candidate, the indices of every OTHER candidate within `threshold`
    /// bits — verified, not merely banded together.
    private static func neighbourLists(
        of candidates: [HashedAsset], within threshold: Int
    ) -> [[Int]] {
        var neighbours = [[Int]](repeating: [], count: candidates.count)
        for (index, others) in bandCandidates(of: candidates, within: threshold) {
            neighbours[index] = others.filter {
                PerceptualHash.hammingDistance(candidates[index].hash, candidates[$0].hash) <= threshold
            }
        }
        return neighbours
    }

    /// Index → the candidate indices sharing at least one exact band with it (a
    /// superset of its true neighbours; ties are broken by ascending index so the
    /// result is deterministic).
    ///
    /// At `threshold == bitCount` every pair is within range and banding has
    /// nothing to prune, so the whole set is returned directly.
    private static func bandCandidates(
        of candidates: [HashedAsset], within threshold: Int
    ) -> [(Int, [Int])] {
        guard threshold < PerceptualHash.bitCount else {
            return candidates.indices.map { index in
                (index, candidates.indices.filter { $0 != index })
            }
        }
        let bands = bandRanges(forThreshold: threshold)
        // One bucket table per band: band value → the indices carrying it.
        var tables = [[UInt64: [Int]]](repeating: [:], count: bands.count)
        for index in candidates.indices {
            for (band, range) in bands.enumerated() {
                tables[band][value(of: candidates[index].hash, in: range), default: []].append(index)
            }
        }
        return candidates.indices.map { index in
            var seen: Set<Int> = []
            for (band, range) in bands.enumerated() {
                for other in tables[band][value(of: candidates[index].hash, in: range)] ?? []
                where other != index {
                    seen.insert(other)
                }
            }
            return (index, seen.sorted())
        }
    }

    /// The `(offset, width)` bit bands the 64-bit hash is split into: `threshold + 1`
    /// disjoint bands, as even as the bit count allows, so the pigeonhole guarantee
    /// holds (see the file header, COST).
    static func bandRanges(forThreshold threshold: Int) -> [(offset: Int, width: Int)] {
        let count = min(threshold + 1, PerceptualHash.bitCount)
        let base = PerceptualHash.bitCount / count
        let remainder = PerceptualHash.bitCount % count
        var ranges: [(offset: Int, width: Int)] = []
        var offset = 0
        for band in 0 ..< count {
            // Spread the leftover bits over the first `remainder` bands rather than
            // piling them onto the last one.
            let width = base + (band < remainder ? 1 : 0)
            ranges.append((offset, width))
            offset += width
        }
        return ranges
    }

    /// The value of one band of `hash`.
    private static func value(of hash: UInt64, in range: (offset: Int, width: Int)) -> UInt64 {
        let mask: UInt64 = range.width >= 64 ? .max : (1 << UInt64(range.width)) - 1
        return (hash >> UInt64(range.offset)) & mask
    }

    // MARK: - Complete-linkage growth

    /// Grow the complete-linkage group seeded by the pair `(seed, partner)`:
    /// every further candidate must be within `threshold` of EVERY member already
    /// in the group, not merely of the seed. Returns the member indices ascending
    /// (= input order).
    private static func grow(
        from seed: Int, and partner: Int,
        candidates: [HashedAsset], neighbours: [[Int]], threshold: Int
    ) -> [Int] {
        var group = [seed, partner]
        // Only the seed's own neighbours can qualify, so this is the whole search
        // space — scanned in ascending index order, which makes the result depend
        // on the input order alone.
        for candidate in neighbours[seed] where candidate != partner {
            let fitsAll = group.allSatisfy {
                PerceptualHash.hammingDistance(
                    candidates[candidate].hash, candidates[$0].hash) <= threshold
            }
            if fitsAll { group.append(candidate) }
        }
        return group.sorted()
    }

    /// The largest pairwise distance among `group`'s members of `candidates`.
    private static func widest(_ group: [Int], in candidates: [HashedAsset]) -> Int {
        var largest = 0
        for (offset, left) in group.enumerated() {
            for right in group[(offset + 1)...] {
                largest = max(
                    largest,
                    PerceptualHash.hammingDistance(candidates[left].hash, candidates[right].hash))
            }
        }
        return largest
    }
}
