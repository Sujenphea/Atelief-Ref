import CoreGraphics

/// The **single source of truth** for the canvas's world↔screen mapping
/// (decision C6). Culling, rendering, and hit-testing all go through this one
/// type so they can never drift apart — the classic "clicks miss the tile" bug
/// is structurally impossible.
///
/// The mapping is a uniform-scale affine: `screen = world * scale + translation`.
/// World and screen share axis orientation here; any AppKit y-flip is applied by
/// the host view, not baked into this math, so the transform stays trivially
/// testable.
///
/// `scale` is **clamped** to `[minScale, maxScale]` at construction, and
/// `minScale` is required to be `> 0`. That single invariant is what makes
/// ``screenToWorld(_:)-3qy9b`` divide-by-zero-proof (decision C7).
public struct CanvasTransform: Equatable, Sendable {
    /// Screen points per world unit. Always `> 0` and within `[minScale, maxScale]`.
    public let scale: CGFloat
    /// Screen-space position of world origin `(0, 0)`.
    public let translation: CGPoint
    /// Smallest permitted ``scale`` (zoomed all the way out). Must be `> 0`.
    public let minScale: CGFloat
    /// Largest permitted ``scale`` (zoomed all the way in).
    public let maxScale: CGFloat

    /// Creates a transform, clamping `scale` into `[minScale, maxScale]`.
    ///
    /// - Precondition: `minScale > 0` and `maxScale >= minScale`.
    public init(
        scale: CGFloat = 1,
        translation: CGPoint = .zero,
        minScale: CGFloat = 0.02,
        maxScale: CGFloat = 64
    ) {
        precondition(minScale > 0, "minScale must be > 0 to keep screenToWorld divide-by-zero-proof")
        precondition(maxScale >= minScale, "maxScale must be >= minScale")
        self.minScale = minScale
        self.maxScale = maxScale
        self.scale = Self.clamp(scale, lower: minScale, upper: maxScale)
        self.translation = translation
    }

    // MARK: World → Screen

    /// Maps a world-space point into screen space.
    public func worldToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + translation.x, y: p.y * scale + translation.y)
    }

    /// Maps a world-space rect into screen space (origin + size both scaled).
    public func worldToScreen(_ r: CGRect) -> CGRect {
        CGRect(
            x: r.origin.x * scale + translation.x,
            y: r.origin.y * scale + translation.y,
            width: r.size.width * scale,
            height: r.size.height * scale
        )
    }

    // MARK: Screen → World

    /// Maps a screen-space point back into world space.
    ///
    /// Safe by construction: ``scale`` is always `>= minScale > 0`.
    public func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - translation.x) / scale, y: (p.y - translation.y) / scale)
    }

    /// Maps a screen-space rect back into world space.
    public func screenToWorld(_ r: CGRect) -> CGRect {
        CGRect(
            x: (r.origin.x - translation.x) / scale,
            y: (r.origin.y - translation.y) / scale,
            width: r.size.width / scale,
            height: r.size.height / scale
        )
    }

    /// The world-space rect currently visible in a viewport of `viewportSize`
    /// (screen points), assuming the viewport's top-left is screen `(0, 0)`.
    ///
    /// This is the input the ``TileCuller`` uses each frame.
    public func visibleWorldRect(viewportSize: CGSize) -> CGRect {
        screenToWorld(CGRect(origin: .zero, size: viewportSize))
    }

    // MARK: Mutations (value semantics)

    /// Returns a copy translated by a screen-space delta (a pan gesture).
    public func panned(byScreenDelta delta: CGSize) -> CanvasTransform {
        CanvasTransform(
            scale: scale,
            translation: CGPoint(x: translation.x + delta.width, y: translation.y + delta.height),
            minScale: minScale,
            maxScale: maxScale
        )
    }

    /// Returns a copy zoomed by `factor` while keeping the world point under
    /// `anchor` (a screen-space point, e.g. the cursor) visually fixed.
    ///
    /// If the new scale hits a clamp limit the anchor still stays fixed, because
    /// the translation is recomputed from the clamped scale.
    public func zoomed(by factor: CGFloat, aroundScreenPoint anchor: CGPoint) -> CanvasTransform {
        let newScale = Self.clamp(scale * factor, lower: minScale, upper: maxScale)
        let worldAtAnchor = screenToWorld(anchor)
        let newTranslation = CGPoint(
            x: anchor.x - worldAtAnchor.x * newScale,
            y: anchor.y - worldAtAnchor.y * newScale
        )
        return CanvasTransform(
            scale: newScale,
            translation: newTranslation,
            minScale: minScale,
            maxScale: maxScale
        )
    }

    // MARK: Camera (018 · Cluster C)

    /// The camera this transform expresses for a viewport of `viewportSize` — the
    /// world point at the viewport's centre, plus the scale.
    public func camera(viewportSize: CGSize) -> CanvasCamera {
        CanvasCamera(
            centre: screenToWorld(
                CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)),
            zoom: scale
        )
    }

    /// A copy that puts `camera`'s world centre at the centre of a `viewportSize`
    /// viewport, at its zoom — the exact inverse of ``camera(viewportSize:)``.
    ///
    /// The translation is recomputed from the CLAMPED scale, so a camera saved by a
    /// build with a wider zoom range still lands centred rather than skidding off
    /// the anchor (the same reasoning as ``zoomed(by:aroundScreenPoint:)``).
    public func settingCamera(_ camera: CanvasCamera, viewportSize: CGSize) -> CanvasTransform {
        let newScale = Self.clamp(camera.zoom, lower: minScale, upper: maxScale)
        return CanvasTransform(
            scale: newScale,
            translation: CGPoint(
                x: viewportSize.width / 2 - camera.centre.x * newScale,
                y: viewportSize.height / 2 - camera.centre.y * newScale
            ),
            minScale: minScale,
            maxScale: maxScale
        )
    }

    // MARK: -

    static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

/// A **window-independent** camera: the world point sitting at the centre of the
/// viewport, plus the zoom (018 · Cluster C).
///
/// Distinct from ``CanvasTransform`` on purpose. A transform's `translation` is a
/// screen offset, and a screen offset only means anything against the window size
/// that produced it — persisting one and restoring it into a different-sized
/// window slides the content by half the difference. A centre does not care how
/// big the window is, so it is what crosses a session boundary.
public struct CanvasCamera: Equatable, Sendable {
    /// The world point drawn at the middle of the viewport.
    public var centre: CGPoint
    /// Screen points per world unit.
    public var zoom: CGFloat

    public init(centre: CGPoint, zoom: CGFloat) {
        self.centre = centre
        self.zoom = zoom
    }
}
