import CoreGraphics

/// LRU cache of decoded thumbnails, keyed by `(imageID, tier)`, with a hard
/// resident-memory ceiling (decision P14).
///
/// This is the canvas's answer to the "N+1" trap: without it, a tile re-entering
/// the viewport during a pan would re-decode every time. With it, decoded images
/// survive realize/derealize cycles, and total resident memory is bounded by the
/// ceiling — which is exactly the memory profile the spike must prove.
@MainActor
final class ThumbnailCache {
    struct Key: Hashable {
        let imageID: Int
        let tier: LODTier
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
    }

    private var entries: [Key: Entry] = [:]
    /// LRU recency order: front = least-recently-used, back = most-recent.
    private var recency: [Key] = []

    /// Approximate resident bytes of all cached decoded images.
    private(set) var residentBytes = 0
    /// Hard ceiling; insertion evicts LRU entries until at or under this.
    let maxBytes: Int

    init(maxBytes: Int = 256 * 1024 * 1024) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
    }

    var count: Int { entries.count }

    /// Returns the cached image and marks it most-recently-used.
    func image(for key: Key) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    /// Inserts (or replaces) an image, then evicts LRU entries until resident
    /// memory is within `maxBytes`. The just-inserted key is never evicted, so a
    /// single oversized image is kept rather than thrashing.
    func insert(_ image: CGImage, for key: Key) {
        if let existing = entries[key] {
            residentBytes -= existing.cost
        }
        let cost = max(1, image.bytesPerRow * image.height)
        entries[key] = Entry(image: image, cost: cost)
        residentBytes += cost
        touch(key)
        evict(protecting: key)
    }

    private func touch(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }

    private func evict(protecting protected: Key) {
        while residentBytes > maxBytes, let lru = recency.first, lru != protected {
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: lru) {
                residentBytes -= removed.cost
            }
        }
    }
}
