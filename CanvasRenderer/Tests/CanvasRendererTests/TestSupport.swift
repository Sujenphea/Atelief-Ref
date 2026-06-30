import CoreGraphics
import Foundation

/// Shared approximate-equality helpers for the geometry suites. Relative
/// tolerance so the large-world-coordinate precision tests (decision C7) stay
/// meaningful without hard-coding an absolute epsilon.
enum Approx {
    static let tolerance: CGFloat = 1e-6

    static func equal(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = tolerance) -> Bool {
        let scale = max(1, abs(a), abs(b))
        return abs(a - b) <= tol * scale
    }

    static func equal(_ a: CGPoint, _ b: CGPoint, tol: CGFloat = tolerance) -> Bool {
        equal(a.x, b.x, tol: tol) && equal(a.y, b.y, tol: tol)
    }

    static func equal(_ a: CGRect, _ b: CGRect, tol: CGFloat = tolerance) -> Bool {
        equal(a.origin, b.origin, tol: tol)
            && equal(a.size.width, b.size.width, tol: tol)
            && equal(a.size.height, b.size.height, tol: tol)
    }
}
