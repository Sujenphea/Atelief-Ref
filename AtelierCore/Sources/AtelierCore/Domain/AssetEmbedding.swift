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

    /// The ``AssetAnalysis/analysisSeq`` this embedding accounted for (v23). Staleness
    /// is `analysis.analysisSeq > embedding.analysisSeq` — an integer comparison, so it
    /// cannot tie the way the old `analyzed_at > embedded_at` did. NULL means the
    /// embedding has not accounted for any analysis yet, which is stale-making.
    public var analysisSeq: Int?

    public var id: UUID { assetID }

    /// Explicit snake_case column/coding names (exact acronym mapping).
    public enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case modelVersion = "model_version"
        case contentHash = "content_hash"
        case vector
        case embeddedAt = "embedded_at"
        case analysisSeq = "analysis_seq"
    }

    public init(
        assetID: UUID,
        modelVersion: Int,
        contentHash: String,
        vector: Data,
        embeddedAt: Date,
        analysisSeq: Int? = nil
    ) {
        self.assetID = assetID
        self.modelVersion = modelVersion
        self.contentHash = contentHash
        self.vector = vector
        self.embeddedAt = embeddedAt
        self.analysisSeq = analysisSeq
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

    /// Whether this machine stores `Float` the way the BLOB does.
    ///
    /// The stored layout is pinned little-endian so a library file is portable.
    /// On a little-endian host that layout is byte-for-byte the in-memory one, so
    /// unpacking is a `memcpy` rather than arithmetic. On a big-endian host it is
    /// not, and ``appendFloats(_:to:)`` takes the lane-by-lane road — which is
    /// the only reason the pinning exists, so the fast path must not quietly
    /// assume it away.
    static let hostMatchesStoredByteOrder = UInt32(1).littleEndian == 1

    /// Unpack `data` into `destination` — the BULK half of the codec, for a
    /// caller that already owns the storage the vector belongs in.
    ///
    /// Same layout, same lane rule, same file: the byte format still has ONE
    /// definition, which is why this lives here rather than in the corpus loader
    /// that wants it. It is `internal` because it hands the caller's memory to
    /// `memcpy`; the public codec stays ``vectorFloats(_:)``.
    ///
    /// **The bulk copy is the point, and it was measured.** Building a resident
    /// 20,000 × 512 matrix is 10.2 million lanes, and unpacked one
    /// `loadUnaligned` at a time that decode was 397 ms of a 443 ms corpus load
    /// at N = 5,000 — the entire cold cost, with SQLite handing over all 20 MB of
    /// blobs in 8.6 ms. Row-at-a-time `memcpy` into a preallocated matrix does
    /// the same load in 14 ms.
    ///
    /// `destination` is typed `Float` storage, so it is aligned by construction
    /// and the `Data`'s own alignment — which nothing guarantees — cannot make
    /// this ill-formed. `Float` has no trap representations, so every 4-byte
    /// group is a value.
    ///
    /// Copies `min(data.count / 4, destination.count)` lanes; the corpus builder
    /// has already refused any row where those differ.
    static func copyVector(_ data: Data, into destination: UnsafeMutableBufferPointer<Float>) {
        let count = min(data.count / 4, destination.count)
        guard count > 0, let base = destination.baseAddress else { return }
        guard hostMatchesStoredByteOrder else {
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    base[i] = Float(bitPattern: UInt32(littleEndian: bits))
                }
            }
            return
        }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(
            start: UnsafeMutableRawPointer(base), count: count * 4))
    }

    /// This row's vector as `[Float]`.
    public var vectorFloats: [Float] { Self.vectorFloats(vector) }
}
