import CoreGraphics
import Foundation
import ImageIO

/// Schedules image decode + downsample **off the main thread** and delivers the
/// result back on the main actor (decision P15). Decoding a >8ms image on the
/// main thread would blow the per-frame budget the instant a tile scrolls in, so
/// it must never happen there.
///
/// Also handles stale-decode cancellation: when ``retainOnly(_:)`` is called each
/// frame, in-flight decodes for tiles that have since been culled are cancelled
/// so we don't pay for work whose result is already irrelevant.
@MainActor
final class DecodeScheduler {
    typealias Key = ThumbnailCache.Key

    private let cache: ThumbnailCache
    private var inFlight: [Key: Task<Void, Never>] = [:]

    /// Called on the main actor whenever a key finishes decoding (and is now in
    /// the cache), so the engine can paint every tile currently using that key.
    var onDecoded: (@MainActor (Key) -> Void)?

    nonisolated private static let decodeQueue = DispatchQueue(
        label: "com.ref-atelier.canvas.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    init(cache: ThumbnailCache) {
        self.cache = cache
    }

    var inFlightCount: Int { inFlight.count }

    /// Requests an async decode for `key` if one isn't already running. No-op if
    /// the key is already in flight.
    func request(key: Key, data: Data, maxPixelSize: Int) {
        guard inFlight[key] == nil else { return }
        let task = Task { [weak self] in
            let decoded = await DecodeScheduler.decode(data: data, maxPixelSize: maxPixelSize)
            guard let self else { return }
            self.inFlight[key] = nil
            guard !Task.isCancelled, let image = decoded?.cgImage else { return }
            self.cache.insert(image, for: key)
            self.onDecoded?(key)
        }
        inFlight[key] = task
    }

    /// Cancels in-flight decodes whose key is not in `keep` (stale tiles).
    func retainOnly(_ keep: Set<Key>) {
        for (key, task) in inFlight where !keep.contains(key) {
            task.cancel()
            inFlight[key] = nil
        }
    }

    /// Synchronous decode on the calling thread — for one-time benchmark cache
    /// warming only, never on the render path.
    static func decodeBlocking(data: Data, maxPixelSize: Int) -> CGImage? {
        makeThumbnail(data: data, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decode(data: Data, maxPixelSize: Int) async -> SendableImage? {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                let image = makeThumbnail(data: data, maxPixelSize: maxPixelSize)
                continuation.resume(returning: image.map(SendableImage.init))
            }
        }
    }

    private nonisolated static func makeThumbnail(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
