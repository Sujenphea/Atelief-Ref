import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("LODPolicy")
struct LODPolicyTests {
    let policy = LODPolicy(lowMaxEdge: 128, mediumMaxEdge: 512, hysteresis: 0.15)

    @Test("tiers are ordered low < medium < full")
    func tierOrdering() {
        #expect(LODTier.low < LODTier.medium)
        #expect(LODTier.medium < LODTier.full)
    }

    // MARK: Base tier (no history)

    @Test("history-free tier selection across the thresholds", arguments: [
        (50.0, LODTier.low),
        (128.0, LODTier.low),     // inclusive lower boundary
        (129.0, LODTier.medium),
        (512.0, LODTier.medium),  // inclusive boundary
        (513.0, LODTier.full),
        (4000.0, LODTier.full),
    ] as [(CGFloat, LODTier)])
    func baseTier(edge: CGFloat, expected: LODTier) {
        #expect(policy.tier(forOnScreenLongestEdge: edge) == expected)
        // previous == nil must match the history-free result.
        #expect(policy.tier(forOnScreenLongestEdge: edge, previous: nil) == expected)
    }

    // MARK: Hysteresis — the same edge resolves differently by history

    @Test("inside the low|medium dead-band the tier sticks to the previous one")
    func deadBandLowMedium() {
        // Boundary 128; dead-band ≈ [108.8, 147.2]. Pick 130, which is inside.
        #expect(policy.tier(forOnScreenLongestEdge: 130, previous: .low) == .low)
        #expect(policy.tier(forOnScreenLongestEdge: 130, previous: .medium) == .medium)
    }

    @Test("inside the medium|full dead-band the tier sticks to the previous one")
    func deadBandMediumFull() {
        // Boundary 512; dead-band ≈ [435.2, 588.8]. Pick 500, which is inside.
        #expect(policy.tier(forOnScreenLongestEdge: 500, previous: .medium) == .medium)
        #expect(policy.tier(forOnScreenLongestEdge: 500, previous: .full) == .full)
    }

    @Test("crossing fully past the upper band switches up")
    func crossesUp() {
        #expect(policy.tier(forOnScreenLongestEdge: 150, previous: .low) == .medium)   // > 147.2
        #expect(policy.tier(forOnScreenLongestEdge: 600, previous: .medium) == .full)  // > 588.8
    }

    @Test("crossing fully past the lower band switches down")
    func crossesDown() {
        #expect(policy.tier(forOnScreenLongestEdge: 100, previous: .medium) == .low)   // < 108.8
        #expect(policy.tier(forOnScreenLongestEdge: 400, previous: .full) == .medium)  // < 435.2
    }

    // MARK: No thrash under jitter

    @Test("jittering within the dead-band never flips the tier")
    func noThrashUnderJitter() {
        // Simulate a zoom hovering around the 128 boundary. Once settled in a
        // tier, small back-and-forth must not oscillate (decision P16).
        var current: LODTier = .low
        for edge in [120.0, 135.0, 142.0, 130.0, 125.0, 140.0, 133.0] as [CGFloat] {
            let next = policy.tier(forOnScreenLongestEdge: edge, previous: current)
            #expect(next == .low, "tier thrashed to \(next) at edge \(edge)")
            current = next
        }
    }

    @Test("a full sweep up then down lands in the expected end tiers")
    func fullSweep() {
        var current: LODTier = .low
        // Ramp the on-screen size up well past both boundaries.
        for edge in [100.0, 200.0, 700.0] as [CGFloat] {
            current = policy.tier(forOnScreenLongestEdge: edge, previous: current)
        }
        #expect(current == .full)
        // Ramp back down well below both boundaries.
        for edge in [400.0, 90.0] as [CGFloat] {
            current = policy.tier(forOnScreenLongestEdge: edge, previous: current)
        }
        #expect(current == .low)
    }
}
