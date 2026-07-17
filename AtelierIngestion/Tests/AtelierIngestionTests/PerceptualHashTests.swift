// AtelierIngestion — perceptual-hash tests (feature 012, I1)
//
// The pure dHash core is pinned exactly (deterministic): known grid → known hash,
// MSB-first bit ordering, and the Hamming metric's algebra. Randomized grids then
// assert the structural invariants (reflexive / symmetric / bounded / stable). The
// byte + CGImage adapters get stability + degenerate-input smoke tests over
// lossless PNG fixtures, asserting decoded behavior — never exact bytes.

import CoreGraphics
import Foundation
import Testing
@testable import AtelierIngestion

@Suite("PerceptualHash")
struct PerceptualHashTests {
    // A 9×8 (72-sample) grid filled with one value, then mutated by callers.
    private static func flatGrid(_ value: UInt8 = 0) -> [UInt8] {
        [UInt8](repeating: value, count: PerceptualHash.reducedWidth * PerceptualHash.reducedHeight)
    }

    // MARK: - Pure dHash: known values

    @Test("a perfectly flat grid hashes to 0 (no left>right anywhere)")
    func flatGridIsZero() {
        #expect(PerceptualHash.dHash(reducedLuminance: Self.flatGrid(0)) == 0)
        #expect(PerceptualHash.dHash(reducedLuminance: Self.flatGrid(255)) == 0)
        #expect(PerceptualHash.dHash(reducedLuminance: Self.flatGrid(128)) == 0)
    }

    @Test("strictly-increasing rows hash to 0; strictly-decreasing rows hash to all-ones")
    func monotoneRows() {
        let w = PerceptualHash.reducedWidth
        let h = PerceptualHash.reducedHeight
        var increasing = [UInt8](repeating: 0, count: w * h)
        var decreasing = [UInt8](repeating: 0, count: w * h)
        for row in 0 ..< h {
            for col in 0 ..< w {
                increasing[row * w + col] = UInt8(col)          // 0,1,…,8  → never left>right
                decreasing[row * w + col] = UInt8(w - 1 - col)  // 8,7,…,0  → always left>right
            }
        }
        #expect(PerceptualHash.dHash(reducedLuminance: increasing) == 0)
        #expect(PerceptualHash.dHash(reducedLuminance: decreasing) == UInt64.max)
    }

    @Test("bit ordering is MSB-first: row0/col0 → bit 63, last row/last col → bit 0")
    func bitOrdering() {
        let w = PerceptualHash.reducedWidth
        let h = PerceptualHash.reducedHeight

        // Only the very first pair (row 0, col 0) is left>right.
        var firstPair = Self.flatGrid(0)
        firstPair[0] = 1  // grid[0] > grid[1]==0
        #expect(PerceptualHash.dHash(reducedLuminance: firstPair) == (UInt64(1) << 63))

        // Only the very last pair (last row, col w-2 vs w-1) is left>right.
        var lastPair = Self.flatGrid(0)
        let lastLeft = (h - 1) * w + (w - 2)
        lastPair[lastLeft] = 1  // grid[lastLeft] > grid[lastLeft+1]==0
        #expect(PerceptualHash.dHash(reducedLuminance: lastPair) == 1)
    }

    @Test("the comparison is strict: equal neighbors set no bit")
    func strictComparison() {
        // Every neighbor equal ⇒ no bit even though values are non-zero.
        #expect(PerceptualHash.dHash(reducedLuminance: Self.flatGrid(200)) == 0)
    }

    @Test("dHash is deterministic — same grid, same hash")
    func deterministic() {
        var grid = Self.flatGrid(0)
        for i in grid.indices { grid[i] = UInt8((i * 37) % 256) }
        #expect(PerceptualHash.dHash(reducedLuminance: grid) == PerceptualHash.dHash(reducedLuminance: grid))
    }

    // MARK: - Hamming distance

    @Test("Hamming distance: reflexive, and known endpoints")
    func hammingKnown() {
        #expect(PerceptualHash.hammingDistance(0, 0) == 0)
        #expect(PerceptualHash.hammingDistance(UInt64.max, UInt64.max) == 0)
        #expect(PerceptualHash.hammingDistance(0, UInt64.max) == 64)      // all bits differ
        #expect(PerceptualHash.hammingDistance(0, 1) == 1)               // one bit differs
        #expect(PerceptualHash.hammingDistance(0b1011, 0b0010) == 2)     // 1011 ^ 0010 = 1001
    }

    @Test("a single-bit flip is always distance 1")
    func singleBitFlip() {
        for bit in 0 ..< 64 {
            let x: UInt64 = 0xA5A5_A5A5_A5A5_A5A5
            let y = x ^ (UInt64(1) << UInt64(bit))
            #expect(PerceptualHash.hammingDistance(x, y) == 1)
        }
    }

    // MARK: - Randomized invariants

    /// A tiny deterministic LCG so "random" grids are reproducible without
    /// `Math.random`/`Date` (both unavailable / non-deterministic here).
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func byte() -> UInt8 { UInt8((next() >> 33) & 0xFF) }
    }

    @Test("randomized grids satisfy the metric invariants (reflexive, symmetric, bounded)")
    func randomizedInvariants() {
        var rng = LCG(state: 0xDEAD_BEEF_CAFE_F00D)
        let count = PerceptualHash.reducedWidth * PerceptualHash.reducedHeight
        var hashes: [UInt64] = []
        for _ in 0 ..< 64 {
            var grid = [UInt8](repeating: 0, count: count)
            for i in 0 ..< count { grid[i] = rng.byte() }
            let h = PerceptualHash.dHash(reducedLuminance: grid)
            // Stable: recomputing the same grid gives the same hash.
            #expect(PerceptualHash.dHash(reducedLuminance: grid) == h)
            hashes.append(h)
        }
        for a in hashes {
            #expect(PerceptualHash.hammingDistance(a, a) == 0)  // reflexive
            for b in hashes {
                let d = PerceptualHash.hammingDistance(a, b)
                #expect(d == PerceptualHash.hammingDistance(b, a))  // symmetric
                #expect((0 ... 64).contains(d))                     // bounded
            }
        }
    }

    // MARK: - CGImage + byte adapters (12A)

    @Test("a solid-color CGImage hashes to 0 through the CGImage seam")
    func solidCGImageIsZero() throws {
        let image = try FixtureImages.makeFilledCGImage(width: 40, height: 40) { context in
            context.setFillColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        #expect(try PerceptualHash.hash(image) == 0)
    }

    @Test("a solid-color image hashes to 0 from bytes")
    func solidImageBytesAreZero() throws {
        let data = try FixtureImages.solidColorImage(width: 64, height: 64, red: 10, green: 20, blue: 30)
        #expect(try PerceptualHash.hash(from: data) == 0)
    }

    @Test("resize stability: the same image at 256px and 128px hashes near-identically")
    func resizeStability() throws {
        // `solidImage` is a smooth horizontal gradient — its reduced 9×8 signature
        // should be essentially size-invariant, so the two hashes sit at a tiny
        // Hamming distance (the whole point of a perceptual hash).
        let big = try FixtureImages.solidImage(width: 256, height: 256, format: .png)
        let small = try FixtureImages.solidImage(width: 128, height: 128, format: .png)
        let distance = PerceptualHash.hammingDistance(
            try PerceptualHash.hash(from: big), try PerceptualHash.hash(from: small))
        #expect(distance <= 6)
    }

    @Test("re-encoding the same pixels (PNG vs JPEG) stays a near-duplicate")
    func reEncodeStability() throws {
        let png = try FixtureImages.solidImage(width: 200, height: 150, format: .png)
        let jpeg = try FixtureImages.solidImage(width: 200, height: 150, format: .jpeg)
        let distance = PerceptualHash.hammingDistance(
            try PerceptualHash.hash(from: png), try PerceptualHash.hash(from: jpeg))
        #expect(distance <= 6)
    }

    @Test("zero bytes throw unreadable")
    func zeroBytesThrows() {
        #expect(throws: ImageError.unreadable) {
            try PerceptualHash.hash(from: FixtureImages.zeroBytes)
        }
    }

    @Test("non-image bytes throw an ImageError")
    func nonImageThrows() {
        #expect {
            try PerceptualHash.hash(from: FixtureImages.nonImageBytes())
        } throws: { error in
            error is ImageError
        }
    }
}
