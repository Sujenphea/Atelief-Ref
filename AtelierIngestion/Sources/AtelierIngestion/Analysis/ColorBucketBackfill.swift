// AtelierIngestion — color bucket derivation pass (085 · C1)
//
// Files each analyzed asset's stored swatches into ``ColorBucket``s and writes
// them through `AppServices.replaceColors`, so the color filter has an indexed
// integer to match on.
//
// **This pass reads no blobs and decodes no images.** The hexes are already in
// `asset_analysis.colors`; the work is `ColorPalette.bucketCoverages` over a JSON
// string. That is the whole reason it exists as its own pass rather than an
// `analyzer_version` bump — a bump would re-decode every image in the library to
// recompute data that is already on disk.
//
// Resumability is free, exactly as in ``AnalysisBackfill``: "has colors, has no
// buckets" is a query, not a ledger, so a killed pass resumes by asking for the
// next batch. One unparseable row never aborts a batch (the 004 batch-outcome
// discipline).
//
// Scheduling is the app's concern, as with every other backfill here.

import AtelierCore
import Foundation

/// The tally of one derivation run — honest partial-outcome reporting.
public struct ColorBucketBackfillOutcome: Sendable, Equatable {
    /// Assets whose buckets were derived and persisted this run.
    public let filed: Int
    /// Assets that errored (unreadable `colors` JSON, write failure) and were
    /// skipped — the batch continued past them.
    public let failed: Int

    public init(filed: Int, failed: Int) {
        self.filed = filed
        self.failed = failed
    }

    /// Total assets attempted this run.
    public var attempted: Int { filed + failed }

    func adding(_ other: ColorBucketBackfillOutcome) -> ColorBucketBackfillOutcome {
        ColorBucketBackfillOutcome(filed: filed + other.filed, failed: failed + other.failed)
    }
}

/// Derives `asset_color` rows from `asset_analysis.colors` (085 · C1). A
/// `Sendable` value type over the one collaborator it needs.
public struct ColorBucketBackfill: Sendable {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// File up to `limit` assets' colors into buckets. Idempotent and resumable:
    /// a filed asset drops out of the next batch.
    ///
    /// An asset whose `colors` JSON does not parse is written as an EMPTY bucket
    /// set — and, crucially, still STAMPED with the palette version, which is
    /// what removes it from the queue. Row count cannot do that: zero rows reads
    /// the same as "not derived yet", so without the stamp such an asset would be
    /// handed back on every pass forever and `drain()` would spin to its cap on
    /// every launch. The honest answer for "we cannot read this palette" is "this
    /// asset has no colors to filter by", not an infinite retry.
    @discardableResult
    public func fileNextBatch(limit: Int) async throws -> ColorBucketBackfillOutcome {
        let ids = try await services.assetIDsNeedingColorBuckets(
            paletteVersion: ColorPalette.version, limit: limit)

        var filed = 0
        var failed = 0
        for id in ids {
            do {
                let analysis = try await services.analysis(for: id)
                let swatches = analysis?.colors.flatMap(ColorSwatch.decodeList(fromJSON:)) ?? []
                var buckets: [Int: Double] = [:]
                for share in ColorPalette.bucketCoverages(for: swatches) {
                    buckets[share.bucket.rawValue] = share.coverage
                }
                try await services.replaceColors(
                    assetID: id, buckets: buckets,
                    paletteVersion: ColorPalette.version)
                filed += 1
            } catch {
                failed += 1
            }
        }
        return ColorBucketBackfillOutcome(filed: filed, failed: failed)
    }

    /// Drain the queue in batches of `batchSize` until it is empty, summing the
    /// outcomes. `maxBatches` bounds a pathological run rather than expressing a
    /// policy — a batch that files nothing also stops the loop, so a permanently
    /// unfilable asset cannot spin forever.
    @discardableResult
    public func drain(batchSize: Int = 200, maxBatches: Int = 10_000) async throws
        -> ColorBucketBackfillOutcome {
        var total = ColorBucketBackfillOutcome(filed: 0, failed: 0)
        for _ in 0..<maxBatches {
            let outcome = try await fileNextBatch(limit: batchSize)
            total = total.adding(outcome)
            if outcome.attempted == 0 { break }
        }
        return total
    }
}
