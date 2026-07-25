// AtelierExport — the lazy image seam (052 · B2, 13A/16A)
//
// The package holds no pixels. During rendering it asks the host for one image
// at a time, sized to that element's on-page footprint, draws it, and lets it go
// before requesting the next — so peak memory tracks a single item, not the
// whole board (052 · 13A). The app implements this over the shared
// `ImageDecoding.thumbnailCGImage(from:maxPixelSize:)` downsampler (052 · 16A:
// reuse the stateless decoder, never the live thumbnail cache).

import CoreGraphics

/// Resolves a ``MoodboardContent/image(id:)`` to a decoded, display-oriented
/// `CGImage` at (or near) a requested size. Called on the render task's thread,
/// once per image element, in `z` order.
///
/// Not required to be `Sendable`: the renderer runs on one thread and never
/// hops the provider across an isolation boundary.
public protocol MoodboardImageProvider {
    /// A display-oriented (EXIF-transformed) image for `id` whose longest edge
    /// is about `maxPixelSize` pixels, or `nil` when the image can't be produced
    /// (missing / unreadable blob). A `nil` return makes the renderer skip the
    /// element and record it in the ``RenderResult/skipped`` report (052 · 7A) —
    /// it is not a hard failure.
    ///
    /// - Parameter maxPixelSize: the target longest edge in pixels, already
    ///   sized to the element's page footprint × the output resolution. Always
    ///   ≥ 1.
    func cgImage(forID id: String, maxPixelSize: Int) -> CGImage?
}
