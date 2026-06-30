import CoreGraphics

/// Discrete level-of-detail tiers (decision P16). The renderer holds a decoded
/// thumbnail per tier; zooming swaps which tier a tile draws from.
public enum LODTier: Int, CaseIterable, Sendable, Comparable {
    /// Smallest thumbnail — tiles that are tiny on screen (zoomed far out).
    case low
    /// Mid thumbnail — typical scanning zoom.
    case medium
    /// Full-resolution — tiles drawn large / zoomed in close.
    case full

    public static func < (lhs: LODTier, rhs: LODTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Chooses an ``LODTier`` from a tile's **on-screen** size, with hysteresis to
/// stop the resolution thrashing when the zoom jitters around a tier boundary
/// (decision P16, C7).
///
/// LOD is keyed on on-screen size rather than global zoom because tiles vary in
/// world size — a large tile and a small tile at the same zoom need different
/// resolutions.
public struct LODPolicy: Sendable {
    /// On-screen longest edge at or below which a tile uses ``LODTier/low``.
    public let lowMaxEdge: CGFloat
    /// On-screen longest edge at or below which a tile uses ``LODTier/medium``
    /// (above it, ``LODTier/full``).
    public let mediumMaxEdge: CGFloat
    /// Fractional dead-band around each boundary (e.g. `0.15` = ±15%). Within the
    /// band the tier sticks to its previous value, preventing swap thrash.
    public let hysteresis: CGFloat

    public init(lowMaxEdge: CGFloat = 128, mediumMaxEdge: CGFloat = 512, hysteresis: CGFloat = 0.15) {
        precondition(lowMaxEdge > 0 && mediumMaxEdge > lowMaxEdge, "thresholds must be positive and ordered")
        precondition(hysteresis >= 0 && hysteresis < 1, "hysteresis must be in [0, 1)")
        self.lowMaxEdge = lowMaxEdge
        self.mediumMaxEdge = mediumMaxEdge
        self.hysteresis = hysteresis
    }

    /// Tier with no history (no hysteresis applied). Used for first placement.
    public func tier(forOnScreenLongestEdge edge: CGFloat) -> LODTier {
        if edge <= lowMaxEdge { return .low }
        if edge <= mediumMaxEdge { return .medium }
        return .full
    }

    /// Tier for `edge`, biased to keep `previous` when `edge` sits inside the
    /// hysteresis band around a boundary. Pass `previous == nil` to fall back to
    /// the history-free ``tier(forOnScreenLongestEdge:)``.
    public func tier(forOnScreenLongestEdge edge: CGFloat, previous: LODTier?) -> LODTier {
        guard let previous else { return tier(forOnScreenLongestEdge: edge) }

        let t1 = lowMaxEdge
        let t2 = mediumMaxEdge
        let up: CGFloat = 1 + hysteresis    // boundary shifted to resist growing
        let down: CGFloat = 1 - hysteresis  // boundary shifted to resist shrinking

        switch previous {
        case .low:
            // Stay low until clearly past the low|medium boundary.
            if edge <= t1 * up { return .low }
            return edge <= t2 * up ? .medium : .full
        case .medium:
            // Stick to medium across both adjacent dead-bands.
            if edge <= t1 * down { return .low }
            if edge <= t2 * up { return .medium }
            return .full
        case .full:
            // Stay full until clearly below the medium|full boundary.
            if edge > t2 * down { return .full }
            return edge <= t1 * down ? .low : .medium
        }
    }
}
