//
//  QuickLookPlanTests.swift
//  AtelierRefsTests
//
//  011-B3 · 7A/12A — the pure Quick Look mapping: media-less items (no on-disk
//  file) are skipped before the panel sees them, and the start index tracks the
//  selection lead into the surviving set. The panel itself is manual-pass only.
//

import Foundation
import Testing
@testable import AtelierRefs
import AtelierCore

@Suite("Quick Look plan")
struct QuickLookPlanTests {

    private func detail(_ kind: AssetKind) -> CollectionItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: kind, blobHash: kind == .image ? "hash" : nil,
            mimeType: kind == .image ? "image/png" : nil, width: nil, height: nil,
            duration: nil, fileSize: nil, downloadState: .downloaded,
            createdAt: Date(), sourceId: sourceID)
        let item = CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date())
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    /// A blob URL for byte-backed kinds only — mirrors `IngestionModel.blobURL`,
    /// which returns nil for media-less kinds.
    private func blobURL(_ d: CollectionItemDetail) -> URL? {
        d.asset.kind == .image ? URL(fileURLWithPath: "/blobs/\(d.asset.id).png") : nil
    }

    @Test("media-less items are skipped, byte items kept in order")
    func skipsMediaLess() {
        let details = [detail(.image), detail(.color), detail(.image), detail(.link)]
        let plan = quickLookPlan(for: details, leadID: nil, blobURL: blobURL)
        #expect(plan.urls.count == 2)   // the two images only
        #expect(plan.startIndex == 0)
    }

    @Test("start index lands on the lead item within the surviving set")
    func startAtLead() {
        let a = detail(.image), b = detail(.color), c = detail(.image)
        // Lead is the SECOND image (c); the skipped color must not shift the index.
        let plan = quickLookPlan(for: [a, b, c], leadID: c.item.id, blobURL: blobURL)
        #expect(plan.urls.count == 2)
        #expect(plan.startIndex == 1)   // c is the 2nd previewable item
    }

    @Test("a lead that is itself media-less falls back to index 0")
    func mediaLessLeadFallsBack() {
        let a = detail(.image), b = detail(.color)
        let plan = quickLookPlan(for: [a, b], leadID: b.item.id, blobURL: blobURL)
        #expect(plan.urls.count == 1)
        #expect(plan.startIndex == 0)
    }

    @Test("an all-media-less selection is empty")
    func allMediaLessEmpty() {
        let plan = quickLookPlan(
            for: [detail(.color), detail(.link), detail(.tweet)],
            leadID: nil, blobURL: blobURL)
        #expect(plan.isEmpty)
    }
}
