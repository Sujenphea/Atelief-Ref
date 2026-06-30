import CoreGraphics

/// Transfers a decoded `CGImage` from a background decode queue back to the main
/// actor.
///
/// `CGImage` is immutable and safe to read from any thread; we create it on the
/// decode queue and only ever *read* it on the main actor, so wrapping it as
/// `@unchecked Sendable` is sound. The wrapper is explicit (decision: explicit
/// over clever) so the boundary crossing is visible rather than silenced with a
/// blanket suppression.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) { self.cgImage = cgImage }
}
