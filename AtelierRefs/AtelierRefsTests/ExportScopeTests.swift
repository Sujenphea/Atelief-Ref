//
//  ExportScopeTests.swift
//  AtelierRefsTests
//
//  The one scope rule all four exports share, now that it is one rule rather than
//  three spellings of it. Pure, so no fixture and no database.
//
//  Two of these cover claims that were previously documented and unverified, and
//  both are the kind a future reader could "fix" in the wrong direction:
//
//   • the selection path matches by MEMBERSHIP id, the right-click path by ASSET
//     id — deliberately different, because a grid selection and a Finder-scope
//     target list are different things;
//   • both return FEED order, never the caller's order.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Export scope: rows + folder name")
struct ExportScopeTests {

    // MARK: - Fixtures

    private func detail(title: String? = nil) -> CollectionItemDetail {
        let assetID = UUID()
        let sourceID = UUID()
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date()),
            asset: Asset(
                id: assetID, kind: .image, blobHash: "abcdef1234567890",
                mimeType: "image/png", width: 10, height: 10, duration: nil,
                fileSize: 100, downloadState: .downloaded, createdAt: Date(),
                name: nil, sourceId: sourceID, payload: nil),
            source: Source(
                id: sourceID, platform: .web, originalURL: nil,
                title: title, capturedAt: Date()))
    }

    // MARK: - Selection scope (membership ids)

    @Test("An empty selection means the whole collection")
    func emptySelectionMeansEverything() {
        let rows = [detail(), detail(), detail()]
        #expect(ExportScope.rows(items: rows, selectedIDs: []).count == 3)
    }

    @Test("A non-empty selection means exactly that selection")
    func selectionWins() {
        let a = detail(), b = detail(), c = detail()
        let picked = ExportScope.rows(items: [a, b, c], selectedIDs: [a.item.id, c.item.id])
        #expect(picked.map(\.item.id) == [a.item.id, c.item.id])
    }

    @Test("Selection matches by MEMBERSHIP id, not asset id")
    func selectionMatchesMembership() {
        let a = detail()
        // The asset id is a different value from the membership id; passing the
        // former must NOT select the row. Getting this backwards is the most likely
        // wrong "fix" to this function.
        #expect(ExportScope.rows(items: [a], selectedIDs: [a.asset.id]).isEmpty)
        #expect(ExportScope.rows(items: [a], selectedIDs: [a.item.id]).count == 1)
    }

    @Test("Selection results keep feed order, not selection order")
    func selectionKeepsFeedOrder() {
        let a = detail(), b = detail(), c = detail()
        // Ask in an order unrelated to the feed; a Set has no order to preserve
        // anyway, which is exactly why the feed decides.
        let picked = ExportScope.rows(
            items: [a, b, c], selectedIDs: [c.item.id, a.item.id])
        #expect(picked.map(\.item.id) == [a.item.id, c.item.id])
    }

    @Test("An id that has left the feed selects nothing and does not crash")
    func staleSelectionIDIsIgnored() {
        let a = detail()
        #expect(ExportScope.rows(items: [a], selectedIDs: [UUID()]).isEmpty)
    }

    // MARK: - Right-click scope (asset ids)

    @Test("Asset-id scope matches by ASSET id, not membership id")
    func assetScopeMatchesAsset() {
        let a = detail()
        #expect(ExportScope.rows(items: [a], assetIDs: [a.item.id]).isEmpty)
        #expect(ExportScope.rows(items: [a], assetIDs: [a.asset.id]).count == 1)
    }

    @Test("Asset-id scope returns FEED order even when asked in reverse")
    func assetScopeKeepsFeedOrder() {
        let a = detail(), b = detail(), c = detail()
        // The claim this pins: a share hands files over in the order the grid shows
        // them, so the caller's ordering is deliberately discarded. Without this
        // test, reverse input would look correct either way.
        let picked = ExportScope.rows(
            items: [a, b, c], assetIDs: [c.asset.id, b.asset.id, a.asset.id])
        #expect(picked.map(\.asset.id) == [a.asset.id, b.asset.id, c.asset.id])
    }

    @Test("An EMPTY asset-id list means nothing, not everything")
    func emptyAssetIDsMeansNothing() {
        let rows = [detail(), detail()]
        // The deliberate asymmetry with the selection form: an explicit empty target
        // list IS a statement — there is nothing to act on. Falling back to the whole
        // collection here would make a right-click on a vanished cell export the lot.
        #expect(ExportScope.rows(items: rows, assetIDs: []).isEmpty)
        #expect(ExportScope.rows(items: rows, selectedIDs: []).count == 2)
    }

    @Test("A duplicate asset id does not duplicate its row")
    func duplicateAssetIDsYieldOneRow() {
        let a = detail()
        #expect(ExportScope.rows(items: [a], assetIDs: [a.asset.id, a.asset.id]).count == 1)
    }

    // MARK: - Folder name

    @Test("The folder name is the collection's, sanitized")
    func folderNameSanitized() {
        #expect(ExportScope.folderName(for: "Refs / Q3") == "Refs Q3")
        #expect(ExportScope.folderName(for: "Refs / Q3: 2026") == "Refs Q3 2026")
        #expect(ExportScope.folderName(for: "Interiors") == "Interiors")
    }

    @Test("A blank name falls back to Refs, never to sanitize's \"image\"")
    func folderNameBlankFallback() {
        // "image" is the right word for one file and the wrong one for a folder.
        #expect(ExportScope.folderName(for: "") == "Refs")
        #expect(ExportScope.folderName(for: "   ") == "Refs")
        #expect(ExportScope.folderName(for: "\n\t ") == "Refs")
    }

    @Test("A folder name can never contain a path separator")
    func folderNameNeverEscapes() {
        for hostile in ["../../etc", "a/b/c", "/absolute", "..", "."] {
            let name = ExportScope.folderName(for: hostile)
            #expect(!name.contains("/"), "\(hostile) → \(name)")
        }
    }
}
