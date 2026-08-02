// AtelierCore — SpaceCamera (018 · Cluster C — camera persistence)
//
// Where a ``Space`` was last looked at, stored as JSON TEXT in `space.camera`
// (migration v17). Exactly the `space_item.style` shape — an opaque TEXT column
// holding an all-optional `Codable` value — so the camera can grow a field later
// (a saved "home" view, a per-window camera) without a second migration.
//
// The stored camera is deliberately WINDOW-INDEPENDENT: `x`/`y` are the world
// point at the CENTRE of the viewport, never the raw screen translation. A
// translation only means anything against the window size that produced it, so a
// board reopened in a differently-sized window would slide; a centre survives the
// resize.
//
// A plain value type: no persistence, no validation (the funnel owns those, C8);
// ``Space`` carries the encoded string, mirroring ``SpaceItem/style``.

import Foundation

/// A space's saved camera (018 · Cluster C). Every field is optional so a blob
/// written by an older or newer build still round-trips; ``resolved`` is the one
/// place that decides whether what survived is actually usable.
public struct SpaceCamera: Sendable, Equatable, Hashable, Codable {
    /// World-space x at the centre of the viewport.
    public var x: Double?
    /// World-space y at the centre of the viewport.
    public var y: Double?
    /// Screen points per world unit (the zoom scale).
    public var zoom: Double?

    public init(x: Double? = nil, y: Double? = nil, zoom: Double? = nil) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    /// Encode to a compact JSON string for the `camera` TEXT column, or `nil` if
    /// encoding fails (which it cannot for a well-formed value). Mirrors
    /// ``ElementStyle/jsonString()``.
    public func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from the `camera` TEXT column; `nil` for a nil / malformed string.
    /// Mirrors ``ElementStyle/init(jsonString:)``.
    public init?(jsonString: String?) {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SpaceCamera.self, from: data)
        else { return nil }
        self = decoded
    }
}

// MARK: - Typed accessor

public extension SpaceCamera {
    /// The three values a camera needs to place a viewport, or `nil` when any is
    /// missing or unusable (non-finite, or a zoom that is not positive).
    ///
    /// Deliberately nil-returning rather than defaulting, unlike
    /// ``ElementStyle``'s accessors: a style has a sensible default for every
    /// field, but "where were you looking" does not — inventing one would open the
    /// board somewhere the user has never been. A half-decoded camera is therefore
    /// treated exactly like a missing one, and the caller re-fits the content.
    var resolved: (x: Double, y: Double, zoom: Double)? {
        guard let x, let y, let zoom,
              x.isFinite, y.isFinite, zoom.isFinite, zoom > 0
        else { return nil }
        return (x, y, zoom)
    }
}
