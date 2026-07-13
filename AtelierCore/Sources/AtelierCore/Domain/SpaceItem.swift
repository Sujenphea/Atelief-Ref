// AtelierCore — SpaceItem + SpaceItemKind + ElementStyle (005 · decision O1)
//
// One row on a ``Space`` board. A SINGLE discriminated table serves two shapes
// of row (005 §entity O1): an ASSET placement (`kind == .asset`, `assetID` set,
// `style` nil) or a freeform ELEMENT (`kind == .frame/.text`, `assetID` nil,
// `style` carrying its ``ElementStyle`` as JSON). The discriminator is validated
// in the write funnel (C8) so the two shapes can never cross. Placement (x/y/w/h/z)
// is ALWAYS present — every board row has a concrete world rect (unlike the
// nullable `collection_item.canvas_*`, where placement is optional).
//
// Plain value types: no persistence here; GRDB conformance lives in
// `Persistence/SpaceItem+GRDB.swift` (A1).

import Foundation

/// What a ``SpaceItem`` row draws (005 §entity). `asset` places a captured
/// ``Asset``; `frame` / `text` are freeform elements (E3). String rawValue =
/// on-disk encoding (C5); extensible later (`rect`, `ellipse`, `line`, …) with
/// no relationship migration.
public enum SpaceItemKind: String, Sendable, Codable, CaseIterable, Hashable {
    case asset
    case frame
    case text
}

/// A freeform element's presentation (005 §schema — `ElementStyle`). Stored as
/// JSON TEXT in `space_item.style` (asset rows leave it nil). Every field is
/// optional so a partially-styled element round-trips; E3 populates these.
public struct ElementStyle: Sendable, Equatable, Hashable, Codable {
    /// Text content (a `text` element) or a `frame`'s label.
    public var text: String?
    /// Point size for `text`.
    public var fontSize: Double?
    /// Text colour, hex `#rrggbb` / `#rrggbbaa`.
    public var textColor: String?
    /// Frame fill colour, hex.
    public var fillColor: String?
    /// Frame border colour, hex.
    public var strokeColor: String?
    /// Frame border width in world units.
    public var strokeWidth: Double?

    public init(
        text: String? = nil,
        fontSize: Double? = nil,
        textColor: String? = nil,
        fillColor: String? = nil,
        strokeColor: String? = nil,
        strokeWidth: Double? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
    }

    /// Encode to a compact JSON string for the `style` TEXT column, or `nil` if
    /// encoding fails (which it cannot for a well-formed value).
    public func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from the `style` TEXT column; `nil` for a nil / malformed string.
    public init?(jsonString: String?) {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ElementStyle.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// One row on a ``Space`` board (005 §entity O1). `assetID` is set iff
/// `kind == .asset` (the FK cascades ONLY asset rows when their asset is
/// deleted); element rows carry `style` instead. Placement mirrors
/// ``CanvasRenderer.Tile`` geometry and is always present.
public struct SpaceItem: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable identity (its own id — the same asset may appear twice in a space).
    public var id: UUID
    /// FK → ``Space`` (CASCADE).
    public var spaceID: UUID
    /// The row's discriminator.
    public var kind: SpaceItemKind
    /// FK → ``Asset`` for `.asset` rows (CASCADE); `nil` for element rows.
    public var assetID: UUID?
    /// World-space x.
    public var x: Double
    /// World-space y.
    public var y: Double
    /// World-space width (> 0).
    public var w: Double
    /// World-space height (> 0).
    public var h: Double
    /// Stacking order (lower draws first).
    public var z: Int
    /// ``ElementStyle`` JSON for element rows; `nil` for asset rows.
    public var style: String?
    /// When added to the space.
    public var createdAt: Date
    /// When last moved / restyled.
    public var updatedAt: Date

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case id
        case spaceID = "space_id"
        case kind
        case assetID = "asset_id"
        case x, y, w, h, z, style
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        spaceID: UUID,
        kind: SpaceItemKind,
        assetID: UUID? = nil,
        x: Double,
        y: Double,
        w: Double,
        h: Double,
        z: Int,
        style: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.spaceID = spaceID
        self.kind = kind
        self.assetID = assetID
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.z = z
        self.style = style
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
