import CoreGraphics
import Foundation
import ImageIO

/// Schedules image decode + downsample **off the main thread** and delivers the
/// result back on the main actor (decision P15). Decoding a >8ms image on the
/// main thread would blow the per-frame budget the instant a tile scrolls in, so
/// it must never happen there. File reads for disk-backed thumbnails also run
/// on this queue (G7) so a mass cache-miss does not stall pan/zoom.
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
    /// the key is already in flight. `data` is already in memory (fixtures).
    func request(key: Key, data: Data, maxPixelSize: Int) {
        request(key: key, maxPixelSize: maxPixelSize) { data }
    }

    /// Requests an async load+decode for `key`. `load` runs on the decode queue
    /// (never the main thread) — use this for on-disk thumbnail URLs (G7).
    func request(key: Key, maxPixelSize: Int, load: @escaping @Sendable () -> Data?) {
        guard inFlight[key] == nil else { return }
        let task = Task { [weak self] in
            let decoded = await DecodeScheduler.loadAndDecode(
                load: load, maxPixelSize: maxPixelSize)
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

    private nonisolated static func loadAndDecode(
        load: @escaping @Sendable () -> Data?,
        maxPixelSize: Int
    ) async -> SendableImage? {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                guard let data = load() else {
                    continuation.resume(returning: nil)
                    return
                }
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
