//
//  MostViewedReorderTests.swift
//  AtelierRefsTests
//
//  036 §3 B4 — the local, pure Most-Viewed reorder that replaces the full
//  `loadContents` reload on detail-close. The load-bearing property is
//  BYTE-IDENTITY with core's SQL order (`view_count DESC, created_at DESC,
//  id DESC`): a local order that isn't identical looks fine until the next real
//  reload snaps items into different places.
//
//  The last test proves identity the honest way — against core's ACTUAL SQL sort
//  over a real (temp) database, not a hand-copied comparator that could drift.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("MostViewedReorder (036 §3 B4)")
struct MostViewedReorderTests {

    // MARK: - Fixtures

    private static let sourceID = UUID()
    private static let collectionID = UUID()

    /// A detail with a controllable `viewCount`, `createdAt`, and asset id (the
    /// three sort keys) plus a distinct membership id (the identity the reorder
    /// preserves / compares). `memberID` defaults distinct so array order is
    /// observable; pass an explicit `assetID` to force a full tie.
    private func item(
        view: Int,
        created: Date,
        assetID: UUID = UUID(),
        memberID: UUID = UUID()
    ) -> CollectionItemDetail {
        let asset = Asset(
            id: assetID, kind: .color, blobHash: nil, mimeType: nil,
            width: nil, height: nil, fileSize: nil, downloadState: .downloaded,
            createdAt: created, sourceId: Self.sourceID, viewCount: view)
        let membership = CollectionItem(
            id: memberID, collectionID: Self.collectionID, assetID: assetID,
            addedAt: created)
        let source = Source(id: Self.sourceID, platform: .localPaste, capturedAt: created)
        return CollectionItemDetail(item: membership, asset: asset, source: source)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func memberOrder(_ result: MostViewedReorderResult) -> [UUID]? {
        if case .reordered(let items) = result { return items.map(\.item.id) }
        return nil
    }

    // MARK: - Comparator matches core's tiebreak, tier by tier

    @Test("view_count DESC wins over created_at and id")
    func viewCountDecides() {
        // Lower view_count but newer + larger id must still lose to higher views.
        let hi = Asset(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            kind: .color, blobHash: nil, mimeType: nil, width: nil, height: nil,
            fileSize: nil, downloadState: .downloaded,
            createdAt: date(0), sourceId: Self.sourceID, viewCount: 5)
        let lo = Asset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            kind: .color, blobHash: nil, mimeType: nil, width: nil, height: nil,
            fileSize: nil, downloadState: .downloaded,
            createdAt: date(1000), sourceId: Self.sourceID, viewCount: 4)
        #expect(mostViewedPrecedes(hi, lo, lhsIndex: 1, rhsIndex: 0))
        #expect(!mostViewedPrecedes(lo, hi, lhsIndex: 0, rhsIndex: 1))
    }

    @Test("view_count tie → created_at DESC decides (newer first)")
    func createdAtDecidesOnViewTie() {
        let newer = item(view: 3, created: date(1000)).asset
        let older = item(view: 3, created: date(0)).asset
        #expect(mostViewedPrecedes(newer, older, lhsIndex: 1, rhsIndex: 0))
        #expect(!mostViewedPrecedes(older, newer, lhsIndex: 0, rhsIndex: 1))
    }

    @Test("view_count + created_at tie → id DESC decides (larger id first)")
    func idDecidesOnFullValueTie() {
        let big = item(
            view: 3, created: date(0),
            assetID: UUID(uuidString: "ffffffff-0000-0000-0000-000000000000")!).asset
        let small = item(
            view: 3, created: date(0),
            assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).asset
        #expect(mostViewedPrecedes(big, small, lhsIndex: 1, rhsIndex: 0))
        #expect(!mostViewedPrecedes(small, big, lhsIndex: 0, rhsIndex: 1))
    }

    // MARK: - Stability

    @Test("full tie (same asset) keeps prior relative order")
    func stableOnFullTie() {
        // A duplicate asset membership: same asset id ⇒ equal on all three real
        // keys, so only stability separates them.
        let assetID = UUID()
        let a = item(view: 2, created: date(0), assetID: assetID)
        let b = item(view: 2, created: date(0), assetID: assetID)
        // Already in Most-Viewed order except for the tie — reorder must not move
        // the duplicate pair. Put a clear winner on top so the array actually sorts.
        let top = item(view: 9, created: date(0))
        let forward = mostViewedReorder(items: [top, a, b], bumps: [:])
        #expect(forward == .unchanged)                 // input already sorted + stable
        // Reversed duplicates stay reversed (stability, not value order).
        let reversed = mostViewedReorder(items: [top, b, a], bumps: [:])
        #expect(reversed == .unchanged)
    }

    // MARK: - Skip when unchanged

    @Test("bumping the top item does not reorder (skip publish)")
    func viewingTopItemIsUnchanged() {
        let items = [
            item(view: 5, created: date(0)),
            item(view: 3, created: date(0)),
            item(view: 1, created: date(0)),
        ]
        let result = mostViewedReorder(items: items, bumps: [items[0].asset.id: 3])
        #expect(result == .unchanged)                  // still on top ⇒ no publish
    }

    @Test("counts changed but order unchanged still skips")
    func countChangeWithoutMoveSkips() {
        // Bump a middle item by an amount too small to overtake the one above it.
        let items = [
            item(view: 10, created: date(0)),
            item(view: 5, created: date(0)),
            item(view: 1, created: date(0)),
        ]
        let result = mostViewedReorder(items: items, bumps: [items[1].asset.id: 2])  // 5 → 7 < 10
        #expect(result == .unchanged)
    }

    // MARK: - Per-id bump application moves items to the right slot

    @Test("a viewed item with enough bumps climbs to its correct position")
    func enoughBumpsClimbs() {
        let top = item(view: 5, created: date(0))
        let mid = item(view: 3, created: date(0))
        let low = item(view: 1, created: date(0))
        let items = [top, mid, low]
        // Bump `low` by 5 → 6, above `top`'s 5. It must land first; the rest hold.
        let result = mostViewedReorder(items: items, bumps: [low.asset.id: 5])
        #expect(memberOrder(result) == [low.item.id, top.item.id, mid.item.id])
    }

    @Test("bump lands an item on an exact tie, resolved by the tiebreak")
    func bumpToTieResolvesByTiebreak() {
        // `low` bumped to exactly `top`'s count; created_at ties, so the larger id
        // wins — identical to what core's SQL would do.
        let bigID = UUID(uuidString: "ffffffff-0000-0000-0000-000000000000")!
        let smallID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let top = item(view: 5, created: date(0), assetID: smallID)
        let low = item(view: 3, created: date(0), assetID: bigID)
        let result = mostViewedReorder(items: [top, low], bumps: [bigID: 2])  // low 3 → 5
        #expect(memberOrder(result) == [low.item.id, top.item.id])            // bigID first
    }

    @Test("empty bumps on an already-sorted array is unchanged")
    func emptyBumpsUnchanged() {
        let items = [
            item(view: 5, created: date(0)),
            item(view: 3, created: date(0)),
        ]
        #expect(mostViewedReorder(items: items, bumps: [:]) == .unchanged)
    }

    // MARK: - Gold standard: identical to core's REAL SQL sort

    /// The proof that matters: run the local reorder and core's actual
    /// `collectionItems(sort: .mostViewed)` over the SAME real database and assert
    /// byte-identical order — so the comparator can't silently drift from core's
    /// `view_count DESC, created_at DESC, id DESC`. Colors seeded in a tight loop
    /// share `created_at` at millisecond resolution, so the untouched majority ties
    /// on view_count AND created_at — exercising the `id DESC` tiebreak against the
    /// database itself, not a hand-copy.
    @Test("local reorder equals core's Most-Viewed SQL order")
    func matchesCoreSQLOrder() async throws {
        let dbPath = NSTemporaryDirectory() + "mvreorder-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let folder = try await services.createCollection(name: "MV")

        // Seed 8 media-less colors (no blobs needed for the sort keys).
        var assetIDs: [UUID] = []
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for i in 0..<8 {
            let hex = String(format: "#%02x%02x%02x", (i * 33 + 7) % 256, (i * 51 + 11) % 256, (i * 91 + 3) % 256)
            let r = try await services.ingestContent(.color(hex: hex), from: source, into: folder.id)
            assetIDs.append(r.asset.id)
        }

        // Baseline order (all view_count 0) BEFORE any views.
        let base = try await services.collectionItems(in: folder.id, sort: .mostViewed)

        // Apply an uneven view spread: one asset viewed 3×, another 1× (each
        // recordViews call = +1 per distinct id, matching the local +1-per-flush).
        let heavy = assetIDs[6], light = assetIDs[2]
        try await services.recordViews([heavy])
        try await services.recordViews([heavy])
        try await services.recordViews([heavy])
        try await services.recordViews([light])

        // Core's truth after the views.
        let coreOrder = try await services.collectionItems(in: folder.id, sort: .mostViewed)
            .map(\.asset.id)

        // Local reorder from the baseline with the same deltas.
        let bumps: [UUID: Int] = [heavy: 3, light: 1]
        let result = mostViewedReorder(items: base, bumps: bumps)
        let localOrder: [UUID]
        switch result {
        case .reordered(let items): localOrder = items.map(\.asset.id)
        case .unchanged:            localOrder = base.map(\.asset.id)
        }

        #expect(localOrder == coreOrder)
    }
}
