import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small set of deterministic, varied **encoded** source images for the spike
/// (decision C8). They are generated procedurally and PNG-encoded in-process —
/// no binary fixtures in the repo — yet the bytes are reproducible (decision
/// T12) and decoding them in Checkpoint 4 incurs *real* Image I/O decode +
/// downsample + texture-upload cost, which solid-colour layers would not.
///
/// PNG (lossless) rather than JPEG specifically because ImageIO's JPEG
/// entropy-coding is **not** byte-deterministic across runs (~1% size jitter),
/// which would defeat T12; PNG encoding is deterministic and the decode +
/// downsample + upload costs the spike cares about are format-independent.
///
/// Tiles map onto this set by `id % count`, so thousands of tiles share a few
/// dozen distinct source images — exactly how a real cache behaves (many tiles,
/// bounded unique blobs).
public struct FixtureImageSet: Sendable {
    /// PNG-encoded source images, varied in size, aspect, and content.
    public let encoded: [Data]

    public var count: Int { encoded.count }

    /// - Parameters:
    ///   - count: number of distinct source images.
    ///   - seed: determinism seed.
    public init(count: Int = 24, seed: UInt64 = 0x00F1) {
        precondition(count >= 1)
        var rng = SeededRandom(seed: seed)
        var images: [Data] = []
        images.reserveCapacity(count)
        for index in 0..<count {
            // Vary source dimensions so downsampling has real, mixed work to do.
            let longEdge = Int.random(in: 640...1536, using: &rng)
            let portrait = Bool.random(using: &rng)
            let shortEdge = Int(Double(longEdge) * Double.random(in: 0.55...0.95, using: &rng))
            let w = portrait ? shortEdge : longEdge
            let h = portrait ? longEdge : shortEdge
            let bitmap = Self.makeBitmap(width: w, height: h, index: index, rng: &rng)
            images.append(Self.encodePNG(bitmap))
        }
        self.encoded = images
    }

    /// The source image data a tile draws from (wraps by `id`, negatives safe).
    public func data(forTileID id: Int) -> Data {
        let i = ((id % encoded.count) + encoded.count) % encoded.count
        return encoded[i]
    }
}

// The spike's image source: tiles map onto the fixed set by `id` (decision C8),
// so `imageKey` is that wrapped index and `imageData` is tier-independent — a
// single source decoded down to each tier's pixel size. Behaviour matches the
// pre-seam engine exactly (it did `id % count` + `data(forTileID:)` inline).
extension FixtureImageSet: TileImageSource {
    public func imageKey(for tile: Tile) -> Int {
        ((tile.id % encoded.count) + encoded.count) % encoded.count
    }

    public func imageData(for tile: Tile, tier: LODTier) -> Data? {
        data(forTileID: tile.id)
    }

    // MARK: - Procedural bitmap

    private static func makeBitmap(width: Int, height: Int, index: Int, rng: inout SeededRandom) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Diagonal gradient background (defeats trivial JPEG compression so the
        // encoded size and decode cost stay realistic).
        let c0 = randomColor(&rng, alpha: 1)
        let c1 = randomColor(&rng, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [c0, c1] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: width, y: height),
                options: []
            )
        }

        // A scatter of translucent rectangles for mid-frequency detail.
        let shapeCount = 12 + (index % 8)
        for _ in 0..<shapeCount {
            let rw = Double.random(in: 0.1...0.4, using: &rng) * Double(width)
            let rh = Double.random(in: 0.1...0.4, using: &rng) * Double(height)
            let rx = Double.random(in: 0...Double(width), using: &rng) - rw / 2
            let ry = Double.random(in: 0...Double(height), using: &rng) - rh / 2
            ctx.setFillColor(randomColor(&rng, alpha: CGFloat.random(in: 0.2...0.6, using: &rng)))
            ctx.fill(CGRect(x: rx, y: ry, width: rw, height: rh))
        }

        return ctx.makeImage()!
    }

    private static func randomColor(_ rng: inout SeededRandom, alpha: CGFloat) -> CGColor {
        CGColor(
            red: CGFloat.random(in: 0...1, using: &rng),
            green: CGFloat.random(in: 0...1, using: &rng),
            blue: CGFloat.random(in: 0...1, using: &rng),
            alpha: alpha
        )
    }

    private static func encodePNG(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
