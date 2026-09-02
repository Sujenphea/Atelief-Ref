// AtelierBrowse — one decode per key, and a bound on what the decodes weigh
// (098 · finding 15).
//
// The phone's `ThumbnailCache` was an `NSCache` and a `Task.detached` per miss. 440 gave
// it a real byte bound after a count limit alone stopped being one; what it never had was
// the other two properties a scroll needs:
//
//   · **Coalescing.** Two views asking for one key decoded it twice. That is not
//     hypothetical on this app: the grid tile and the switcher's collection row resolve to
//     the SAME 512-tier path by construction (`BrowseLibrary.collectionCovers` returns
//     `gridThumbnailURL(forHash:)`, and `BrowseLibraryTests` pins it), and the detail
//     screen re-asks for a tier the grid may still be decoding.
//   · **Cancellation.** A tile scrolled off cancels the SwiftUI `task`, and the detached
//     decode carried on regardless — then inserted, evicting something still on screen.
//
// **Generic, and deliberately not over `UIImage`.** This package must build without UIKit,
// which is the property that makes every test here run under `swift test` on a host with
// no simulator. The value type is a parameter, its byte cost is an injected function, and
// the decode itself is an injected closure — so the tests use a fake decoder that counts
// its calls and parks on a `Gate`, and the app's instantiation over
// `ImageDecoding.decodedThumbnail` is four lines in `ThumbnailImage.swift`.
//
// **Why not `NSCache`.** It was the previous implementation and it has one real advantage:
// it purges under memory pressure by itself. It also evicts on rules Apple does not
// specify, which makes "the byte bound is honoured" a claim no test can make. The bound is
// the thing 440 was written to get, so the store here is an explicit LRU that can be
// asserted, and the pressure response is the app's — `ThumbnailCache` calls ``purge()``
// from `UIApplication.didReceiveMemoryWarningNotification`, which is one line in the
// target that already has UIKit.

import Foundation

/// The budgets, carried over from the phone's `ThumbnailCache` along with the arguments
/// that chose them (440). A namespace so a generic type can name them — Swift has no
/// static stored properties on a generic type, and these are not per-instantiation
/// anyway.
public enum DecodeBudget {
    /// The ceiling on decoded bytes held at once — **96 MB**.
    ///
    /// **A count limit alone stopped being a bound once the detail screen shared this
    /// cache.** The original reasoning was that these are display tiers and a phone screen
    /// holds a dozen, so 240 was generous rather than dangerous. That describes what is
    /// VISIBLE; the cache retains 240 whatever is on screen, and it holds two populations
    /// four times apart in size:
    ///
    ///   · a grid tile is the 512 tier decoded to a column width — ~570px on a 2-column
    ///     phone layout, so roughly 1.3 MB of RGBA;
    ///   · a detail image is the 1280 tier decoded to the full screen width — ~1170px, so
    ///     roughly 5.5 MB.
    ///
    /// 240 of the second is well over a gigabyte. 96 MB holds several screenfuls of tiles
    /// plus a handful of detail images — the working set of actually paging around a
    /// library — and leaves the rest to be re-decoded, which is cheap because the files on
    /// disk are already small JPEGs.
    public static let bytes = 96 * 1024 * 1024

    /// The coarse bound, kept as well as the byte one. They answer different questions:
    /// 240 caps how many KEYS can pile up, ``bytes`` caps what those keys can weigh.
    /// Whichever is reached first evicts.
    public static let count = 240
}

/// A keyed cache of decoded objects: byte- and count-bounded, one decode per key however
/// many callers ask at once, and cancellable.
///
/// An `actor` rather than a lock, because the interesting state is the set of decodes
/// currently in flight and every operation on it is already `async`.
public actor DecodeCache<Key: Hashable & Sendable, Value: AnyObject & Sendable> {

    /// What the cache has been doing. Read by the app behind `-atelier-log-tile-bodies`,
    /// so a fling over a real library can be counted rather than reasoned about, and by
    /// the tests as the whole assertion that coalescing happened.
    public struct Statistics: Sendable, Equatable {
        /// Answered from memory.
        public var hits = 0
        /// Decodes actually started — the number a device measurement is after.
        public var decodes = 0
        /// Callers that joined a decode already in flight instead of starting one. This
        /// is the number that says whether coalescing is worth having on real hardware.
        public var coalesced = 0
        /// Decodes whose caller was cancelled before the result could be stored.
        public var abandoned = 0
        /// Entries dropped to stay inside the budgets.
        public var evictions = 0
    }

    private struct Entry {
        let value: Value
        let cost: Int
        var stamp: UInt64
    }

    private let byteBudget: Int
    private let countLimit: Int
    private let cost: @Sendable (Value) -> Int
    private let decode: @Sendable (Key) async -> Value?

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<Value?, Never>] = [:]
    private var totalCost = 0
    /// A monotonic tick, bumped on every read and every insert. The LRU victim is the
    /// smallest stamp — an explicit number rather than an ordered collection, because at
    /// 240 entries a linear scan for the minimum costs less than maintaining a list.
    private var clock: UInt64 = 0
    private var statistics = Statistics()

    /// - Parameters:
    ///   - byteBudget: the ceiling on ``cost`` summed over what is held.
    ///   - countLimit: the ceiling on how many keys are held.
    ///   - cost: what one value weighs. The real bitmap allocation, not a guess from the
    ///     point size, so a wide panorama and a tall skyscraper at the same decode size
    ///     are charged what they each actually cost.
    ///   - decode: produce the value for a key, or `nil` when there is nothing to produce.
    ///     Runs OFF this actor (`Task.detached`), so a decode never blocks a lookup.
    public init(
        byteBudget: Int = DecodeBudget.bytes,
        countLimit: Int = DecodeBudget.count,
        cost: @escaping @Sendable (Value) -> Int,
        decode: @escaping @Sendable (Key) async -> Value?
    ) {
        self.byteBudget = byteBudget
        self.countLimit = countLimit
        self.cost = cost
        self.decode = decode
    }

    // MARK: - The one entry point

    /// The value for `key`, from memory or from one decode.
    ///
    /// **One decode per key.** A second caller arriving while a decode is in flight joins
    /// it rather than starting another; both get the same object, and `decode` is called
    /// once. This is the property the grid and the switcher need, since they resolve to
    /// the same tier path for the same collection cover.
    ///
    /// **Cancellation is observed twice, and both are deliberate.** Before a decode
    /// starts, because a tile that has already scrolled off should not begin work; and
    /// before the result is stored, because inserting a bitmap nobody is waiting for
    /// evicts one that IS on screen. A cancelled caller therefore gets `nil` and leaves
    /// nothing behind. The decode itself is not cancelled — it is shared, and another
    /// caller may still be waiting on it.
    ///
    /// `nil` is a normal answer, not an error: a library whose thumbnails have not been
    /// generated yet has rows and no files.
    public func value(for key: Key) async -> Value? {
        if let hit = lookup(key) {
            statistics.hits += 1
            return hit
        }
        // Before the decode starts.
        guard !Task.isCancelled else { return nil }

        let task: Task<Value?, Never>
        if let existing = inFlight[key] {
            statistics.coalesced += 1
            task = existing
        } else {
            statistics.decodes += 1
            let decode = decode
            task = Task.detached(priority: .userInitiated) { await decode(key) }
            inFlight[key] = task
        }

        let decoded = await task.value
        // Only the entry this call is still looking at: a later miss on the same key may
        // already have installed a fresh task.
        if inFlight[key] == task { inFlight.removeValue(forKey: key) }

        // Before the insert.
        guard !Task.isCancelled else {
            statistics.abandoned += 1
            return nil
        }
        if let decoded { insert(decoded, for: key) }
        return decoded
    }

    // MARK: - Observation

    /// What the cache has been doing. See ``Statistics``.
    public func stats() -> Statistics { statistics }

    /// How many entries are held.
    public var count: Int { entries.count }

    /// What those entries weigh, by ``cost``.
    public var bytes: Int { totalCost }

    /// Drop everything held. In-flight decodes are left alone — their callers are still
    /// waiting, and the result of one is smaller than the working set this just released.
    ///
    /// The app calls this on a memory warning, which is the one thing `NSCache` did for
    /// free and this does on request.
    public func purge() {
        statistics.evictions += entries.count
        entries.removeAll(keepingCapacity: true)
        totalCost = 0
    }

    // MARK: - The store

    private func lookup(_ key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key]?.stamp = clock
        return entry.value
    }

    private func insert(_ value: Value, for key: Key) {
        if let existing = entries[key] { totalCost -= existing.cost }
        clock &+= 1
        // A negative cost from a caller's function would corrupt the accounting into
        // never evicting; a value with no measurable backing is charged nothing rather
        // than crashing it.
        let charge = max(0, cost(value))
        entries[key] = Entry(value: value, cost: charge, stamp: clock)
        totalCost += charge
        evict()
    }

    /// Evict least-recently-used entries until both budgets hold.
    ///
    /// `entries.count > 1` in the guard rather than `> 0`: a single value larger than the
    /// whole byte budget must not evict itself in a loop that then finds nothing to drop.
    /// It stays, alone and over budget, and the NEXT insert removes it — which is the
    /// least surprising thing to do with a value a caller is holding a reference to anyway.
    private func evict() {
        while entries.count > countLimit
            || (totalCost > byteBudget && entries.count > 1) {
            guard let victim = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key
            else { return }
            totalCost -= entries[victim]?.cost ?? 0
            entries.removeValue(forKey: victim)
            statistics.evictions += 1
        }
    }
}

// MARK: - What size to decode at

/// The pixel size a cell's decode is asked for, rounded into buckets.
///
/// Moved out of `ThumbnailImage.maxPixel` (098 · finding 15) because it is arithmetic with
/// two edge cases and it decides how many entries the cache above ends up holding — every
/// distinct answer here is a distinct key for the same file.
public enum DecodeSize {
    /// The rounding step. A handful of nearby widths therefore share one cache entry, so
    /// a rotation or a layout that nudges a column by a point does not throw the decode
    /// away and start again.
    public static let bucket = 128

    /// `width` points at `scale` pixels per point, rounded UP to the next ``bucket``, with
    /// one bucket as the floor.
    ///
    /// Rounded up rather than to nearest, because a decode smaller than the cell is a
    /// visibly soft tile and a decode slightly larger is not visible at all.
    ///
    /// A width that is zero, negative, not finite, or absurd answers one bucket. A
    /// `GeometryReader` reports zero on its first pass, and `Int(Double.nan)` is a trap
    /// rather than a wrong answer — this used to be an unguarded `Int((width *
    /// scale).rounded(.up))` on the render path.
    public static func maxPixel(width: Double, scale: Double) -> Int {
        let pixels = width * scale
        guard pixels.isFinite, pixels > 0, pixels < 1e9 else { return bucket }
        let rounded = Int(pixels.rounded(.up))
        return max(bucket, ((rounded + bucket - 1) / bucket) * bucket)
    }
}
