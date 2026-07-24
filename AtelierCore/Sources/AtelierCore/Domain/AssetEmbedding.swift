// AtelierCore — on-device semantic text embedding (044 · 047 · search Phase 3a)
//
// One dense vector per asset capturing the MEANING of its human text (title +
// user name + note + OCR), produced on-device by `NLEmbedding.sentenceEmbedding`
// and searched by cosine similarity (kNN). Separate from `asset_analysis` so a
// model upgrade re-embeds without re-running OCR/colors/phash (own `modelVersion`).
//
// The vector is stored OPAQUELY as a `Data` BLOB (512 × Float32, little-endian);
// the `[Float]` ↔ `Data` codec lives here so the byte layout has ONE definition.
// `contentHash` is a hash of the exact embedded text, so the backfill re-embeds
// when the text changes (rename / late OCR) even though `asset` has no
// `updated_at` — the 4A staleness signal.
//
// Plain value type (mirrors `AssetAnalysis`): the GRDB conformance lives in
// `Persistence/AssetEmbedding+GRDB.swift`, the mutation funnel in `AppServices`.

import Foundation

/// One asset's semantic text embedding (047 · 3a). `modelVersion` + `contentHash`
/// together drive re-embedding: a model upgrade (`WHERE model_version < …`) or a
/// text change (hash mismatch) marks the row stale.
public struct AssetEmbedding: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The embedded asset (FK → `asset.id`, CASCADE). Also the primary key — one
    /// embedding row per asset. Doubles as `Identifiable.id`.
    public var assetID: UUID
    /// The embedding-model version that produced this row (drives re-embedding).
    public var modelVersion: Int
    /// A stable hash of the exact text that was embedded (title+name+note+OCR).
    /// A mismatch against the freshly-built corpus means the text changed → stale.
    public var contentHash: String
    /// The dense vector as an opaque BLOB (512 × Float32, little-endian). Decode
    /// with ``vectorFloats(_:)`` / encode with ``encode(_:)``.
    public var vector: Data
    /// When this embedding was produced.
    public var embeddedAt: Date

    public var id: UUID { assetID }

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case modelVersion = "model_version"
        case contentHash = "content_hash"
        case vector
        case embeddedAt = "embedded_at"
    }

    public init(
        assetID: UUID,
        modelVersion: Int,
        contentHash: String,
        vector: Data,
        embeddedAt: Date
    ) {
        self.assetID = assetID
        self.modelVersion = modelVersion
        self.contentHash = contentHash
        self.vector = vector
        self.embeddedAt = embeddedAt
    }
}

// MARK: - Vector BLOB codec ([Float] ↔ Data, 512 × Float32 little-endian)

extension AssetEmbedding {
    /// Pack a vector as little-endian Float32 bytes. Endianness is pinned (not
    /// host order) so a library file is portable across architectures.
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpack little-endian Float32 bytes back to a vector. Trailing bytes that
    /// don't complete a 4-byte lane are ignored (a well-formed BLOB has none).
    public static func vectorFloats(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in
                let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    /// This row's vector as `[Float]`.
    public var vectorFloats: [Float] { Self.vectorFloats(vector) }
}
