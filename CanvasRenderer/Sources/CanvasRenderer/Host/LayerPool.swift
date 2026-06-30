import QuartzCore

/// Recycles `CALayer`s so panning doesn't churn allocations (decision A1: the
/// "realize only visible tiles, reuse the layers" core of the CA approach).
///
/// The engine obtains a layer when a tile scrolls into view and recycles it when
/// the tile scrolls out. Checkpoint 5 asserts the invariants this enables:
/// `inUseCount` tracks visible tiles exactly, and `allocatedCount` stays bounded
/// (no per-pan leak).
@MainActor
final class LayerPool {
    private var free: [CALayer] = []
    private let make: @MainActor () -> CALayer

    /// Layers currently handed out (attached to the canvas).
    private(set) var inUseCount = 0

    init(make: @escaping @MainActor () -> CALayer = LayerPool.defaultMake) {
        self.make = make
    }

    /// Idle layers retained for reuse.
    var freeCount: Int { free.count }
    /// Total layers this pool has created and not released (`inUse + free`).
    var allocatedCount: Int { inUseCount + free.count }

    /// Returns a layer ready to attach — reused from the free list when possible.
    func obtain() -> CALayer {
        inUseCount += 1
        if let reused = free.popLast() {
            return reused
        }
        return make()
    }

    /// Detaches a layer from the canvas, clears its contents, and parks it for
    /// reuse.
    func recycle(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        layer.contents = nil
        free.append(layer)
        inUseCount -= 1
    }

    static func defaultMake() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        return layer
    }
}
