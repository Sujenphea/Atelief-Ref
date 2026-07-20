//
//  MasonryCellEquatableTests.swift
//  AtelierRefsTests
//
//  037 / 035 §5 Option A — the guard on ``MasonryCellView/==``.
//
//  `.equatable()` is the entire performance claim of Option A AND its entire risk
//  surface. 035 §5 states it exactly: "every appearance-affecting input MUST be in
//  `==`, or that cell goes stale." The failure mode is nasty precisely because it
//  is quiet — an omitted field produces no crash, no warning, and no slowdown,
//  just a cell that stops updating. It cannot be caught by a smoke test either,
//  since the cell renders perfectly on first appearance and only goes wrong once
//  something changes about it.
//
//  So the omitted-field bug is tested head-on, mechanically: ONE test per stored
//  property, each changing that property ALONE against a fixed baseline and
//  asserting `==` returns false. Change-alone (rather than a bundle of changes) is
//  what makes it a real guard — a test that varied three fields at once would
//  still pass with two of them missing from `==`.
//
//  The last test is the mirror image: identical inputs must compare EQUAL, since
//  an `==` that is merely always-false would pass every test above while
//  delivering none of the performance the mode exists to measure.
//
//  These are pure value comparisons, so they need no running view — the same
//  discipline as `GridWindowingTests` and `MarqueeMathTests`.
//

import AtelierCore
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("MasonryCellView: == covers every appearance-affecting input")
@MainActor
struct MasonryCellEquatableTests {

    // MARK: - Fixtures

    /// One stable hover sink shared by every cell built here. It is a reference the
    /// grid owns for its whole lifetime and deliberately NOT part of `==`, so
    /// holding one constant instance is exactly what production does — and it keeps
    /// the sink from being an accidental source of inequality in these tests.
    private let sink = BakeoffHoverSink()

    /// Fixed ids so the baseline and every variant describe the SAME item unless a
    /// test deliberately changes it. Random ids per call would make `identity()`
    /// pass trivially and, worse, would make the `identical` test fail for the
    /// wrong reason.
    private static let itemID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let assetID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private static let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    private static let collectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
    private static let epoch = Date(timeIntervalSince1970: 0)

    private func detail(
        itemID: UUID = MasonryCellEquatableTests.itemID,
        width: Int? = 200,
        height: Int? = 100
    ) -> CollectionItemDetail {
        let source = Source(id: Self.sourceID, platform: .web, capturedAt: Self.epoch)
        let asset = Asset(
            id: Self.assetID, kind: .image, blobHash: "hash", mimeType: "image/png",
            width: width, height: height, duration: nil, fileSize: 100,
            downloadState: .downloaded, createdAt: Self.epoch, sourceId: Self.sourceID)
        let item = CollectionItem(
            id: itemID, collectionID: Self.collectionID, assetID: Self.assetID,
            addedAt: Self.epoch)
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    /// The baseline cell every test varies exactly one property of.
    private func cell(
        detail: CollectionItemDetail? = nil,
        frame: CGRect = CGRect(x: 10, y: 20, width: 200, height: 100),
        url: URL? = URL(fileURLWithPath: "/tmp/thumb-512.jpg"),
        gifURL: URL? = nil,
        isSelected: Bool = false,
        isCursor: Bool = false,
        isSelecting: Bool = false,
        showsCircle: Bool = false,
        actionTargets: [UUID] = [MasonryCellEquatableTests.assetID],
        moveTargets: MoveTargets = MoveTargets(subfolders: [], roots: []),
        wrappers: GridBakeoffWrapperConfig = .full
    ) -> MasonryCellView {
        MasonryCellView(
            detail: detail ?? self.detail(),
            frame: frame,
            url: url,
            gifURL: gifURL,
            isSelected: isSelected,
            isCursor: isCursor,
            isSelecting: isSelecting,
            showsCircle: showsCircle,
            actionTargets: actionTargets,
            moveTargets: moveTargets,
            wrappers: wrappers,
            hover: sink)
    }

    private func collection(_ name: String) -> Collection {
        Collection(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            name: name, description: nil, coverAssetID: nil,
            createdAt: Self.epoch, updatedAt: Self.epoch, parentCollectionID: nil)
    }

    // MARK: - One test per appearance-affecting input

    @Test("a different item id invalidates — the cell is showing a different item")
    func identity() {
        let other = detail(itemID: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!)
        #expect(cell() != cell(detail: other))
    }

    @Test("a different asset invalidates — the thumbnail renders from it")
    func asset() {
        // Same item id, different intrinsic size: `AssetContentThumbnail` draws from
        // the asset, so a cell that ignored it would keep the old picture. This is
        // also the field `CollectionCell.==` compares, and the outer cell must never
        // be more permissive than the inner one or it would skip a rebuild the inner
        // one needed.
        #expect(cell() != cell(detail: detail(width: 999, height: 111)))
    }

    @Test("a different frame invalidates — zoom / resize changes the drawn size")
    func frame() {
        // Size change (a density zoom or a column-count change).
        #expect(cell() != cell(frame: CGRect(x: 10, y: 20, width: 300, height: 100)))
        // Origin change too: the caller offsets by the frame origin, so a cell that
        // compared only the size would be placed at a new origin while its body was
        // built for the old one.
        #expect(cell() != cell(frame: CGRect(x: 11, y: 20, width: 200, height: 100)))
    }

    @Test("a different thumbnail url invalidates — else the cell keeps a placeholder")
    func thumbnailURL() {
        #expect(cell() != cell(url: URL(fileURLWithPath: "/tmp/other-512.jpg")))
        // nil → non-nil is the case that matters most in practice: it is the moment
        // a freshly-derived thumbnail lands on disk for a cell already on screen.
        #expect(cell(url: nil) != cell())
    }

    @Test("a different gif url invalidates — else a GIF cell can never animate")
    func gifURL() {
        #expect(cell() != cell(gifURL: URL(fileURLWithPath: "/tmp/original.gif")))
    }

    @Test("isSelected invalidates — the check fill and selection border")
    func selected() {
        #expect(cell() != cell(isSelected: true))
    }

    @Test("isCursor invalidates — the keyboard cursor's focus ring")
    func cursor() {
        #expect(cell() != cell(isCursor: true))
    }

    @Test("isSelecting invalidates — circles appear on ALL cells in selection mode")
    func selecting() {
        #expect(cell() != cell(isSelecting: true))
    }

    @Test("showsCircle invalidates — this is what a hover changes")
    func circle() {
        // The most visible form of the stale-cell bug: omit this and hover stops
        // working entirely, on every cell, in a way that looks like a hit-testing
        // problem rather than an equality one.
        #expect(cell() != cell(showsCircle: true))
    }

    @Test("actionTargets invalidates — the drag payload and the menu's counted verbs")
    func dragAndMenuTargets() {
        // The worst stale-cell variant of them all. `actionTargets` is what the
        // `.draggable` payload carries, so a cell that kept a stale copy would drag
        // the WRONG ASSETS — a data-destroying move, not a cosmetic glitch. It also
        // drives "Delete (N)" / "Remove from Collection (N)" and the `n == 1`
        // "Set as Cover" branch, so all three would misreport scope too.
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        // Growing the selection while this cell stays selected: same length change
        // a real ⌘-click produces.
        #expect(cell() != cell(actionTargets: [Self.assetID, other]))
        // And a same-LENGTH change — a cell that compared only `count` (an easy
        // "optimisation" on an array field) would pass the test above and still
        // drag the wrong item.
        #expect(cell() != cell(actionTargets: [other]))
    }

    @Test("moveTargets invalidates — the context menu enumerates them")
    func targets() {
        let dests = MoveTargets(subfolders: [], roots: [collection("Inbox")])
        #expect(cell() != cell(moveTargets: dests))
        // And a RENAME, not just a count change — `MoveTargets` compares its
        // `Collection`s by value, so the menu label tracks the folder name.
        let renamed = MoveTargets(subfolders: [], roots: [collection("Archive")])
        #expect(cell(moveTargets: dests) != cell(moveTargets: renamed))
    }

    @Test("wrappers invalidates — it selects which branch body builds (037 §2)")
    func wrapperConfig() {
        // Constant within a bake-off run, which is exactly why it is the kind of
        // input that gets left out of `==` — and then a mid-session mode switch
        // leaves every cell rendering the other configuration's tree, silently
        // measuring the wrong thing.
        #expect(cell() != cell(wrappers: .stripped))
    }

    // MARK: - The other direction

    @Test("identical inputs compare equal — the skip that makes Option A fast")
    func identical() {
        // Without this, an `==` that always returned false would satisfy every test
        // above while rebuilding all ~100 windowed cells on each band crossing —
        // i.e. behaving exactly like the baseline it is supposed to beat.
        #expect(cell() == cell())
    }

    @Test("equality holds across separately-built but equal values")
    func identicalAcrossFreshValues() {
        // Guards the subtler version of the same failure: the inputs a real band
        // crossing hands a cell are freshly CONSTRUCTED values (a re-read detail, a
        // recomputed frame, a re-derived URL), not the same instances. If `==` were
        // accidentally reference- or instance-sensitive it would compare unequal
        // here and the skip would never fire in practice, while `identical()` above
        // still passed.
        let a = cell(
            detail: detail(),
            frame: CGRect(x: 10, y: 20, width: 200, height: 100),
            url: URL(fileURLWithPath: "/tmp/thumb-512.jpg"),
            // Two SEPARATELY allocated arrays with equal contents — the case that
            // matters for `actionTargets`, whose cheapness relies on Swift's
            // identical-buffer fast path but whose CORRECTNESS must not.
            actionTargets: [Self.assetID, Self.itemID],
            moveTargets: MoveTargets(subfolders: [], roots: [collection("Inbox")]))
        let b = cell(
            detail: detail(),
            frame: CGRect(x: 10, y: 20, width: 200, height: 100),
            url: URL(fileURLWithPath: "/tmp/thumb-512.jpg"),
            actionTargets: [Self.assetID, Self.itemID],
            moveTargets: MoveTargets(subfolders: [], roots: [collection("Inbox")]))
        #expect(a == b)
    }
}

/// The seeded fidelity fixtures both SwiftUI modes share (037).
///
/// These exist because the bake-off's SwiftUI cells previously STUBBED the
/// expensive per-cell work — a 1×1 drag preview, a one-button menu, no marquee
/// layers, `isSelected`/`isCursor` hardwired `false` — and every one of those
/// divergences made the harness CHEAPER than production. A one-directional bias
/// inverts the experiment: it can honestly reject SwiftUI but never honestly
/// accept it. What is asserted here is the property that makes the restored
/// fixtures safe to trust: they are DETERMINISTIC, so the two modes are seeded
/// identically by construction rather than by hope.
@Suite("Bake-off fidelity fixtures are deterministic and identical across modes")
@MainActor
struct BakeoffCellFidelityTests {
    private static let epoch = Date(timeIntervalSince1970: 0)

    private func items(_ n: Int) -> [CollectionItemDetail] {
        (0..<n).map { i in
            let sourceID = UUID()
            let assetID = UUID()
            let source = Source(id: sourceID, platform: .web, capturedAt: Self.epoch)
            let asset = Asset(
                id: assetID, kind: .image, blobHash: "hash-\(i)", mimeType: "image/png",
                width: 200, height: 100, duration: nil, fileSize: 100,
                downloadState: .downloaded, createdAt: Self.epoch, sourceId: sourceID)
            let item = CollectionItem(
                id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Self.epoch)
            return CollectionItemDetail(item: item, asset: asset, source: source)
        }
    }

    @Test("the seeded selection is a scattered ~10% with no randomness")
    func seedShape() {
        let set = items(100)
        let sel = BakeoffCellFidelity.selection(for: set)
        #expect(sel.selection.ids.count == 10)
        #expect(sel.selectedAssetIDs.count == 10)
        // Scattered, not contiguous: a contiguous block would leave most screenfuls
        // entirely unselected and understate the per-cell cost being measured.
        #expect(sel.selection.ids.contains(set[0].item.id))
        #expect(!sel.selection.ids.contains(set[1].item.id))
        #expect(sel.selection.ids.contains(set[10].item.id))
        // A `lead` exists, so exactly one visible cell draws the cursor ring —
        // production always has one once anything is selected.
        #expect(sel.selection.lead == set[0].item.id)
        #expect(sel.selection.isSelecting)
    }

    @Test("seeding the same items twice yields the same selection — both modes match")
    func seedIsDeterministic() {
        // The two grid files each call this builder with the harness's identical
        // `context.items`. If it were random (or order-dependent), the two modes
        // would run different workloads and the comparison would be void — the
        // failure this test exists to make impossible.
        let set = items(50)
        let a = BakeoffCellFidelity.selection(for: set)
        let b = BakeoffCellFidelity.selection(for: set)
        #expect(a.selection == b.selection)
        #expect(a.selectedAssetIDs == b.selectedAssetIDs)
    }

    @Test("actionTargets follows production's scope rule")
    func actionTargetScope() {
        let set = items(30)
        let sel = BakeoffCellFidelity.selection(for: set)
        // A SELECTED cell acts on the whole selection (`IngestionModel`'s cached
        // list), an UNSELECTED cell acts on itself alone.
        #expect(sel.actionTargets(for: set[0]) == sel.selectedAssetIDs)
        #expect(sel.actionTargets(for: set[1]) == [set[1].asset.id])
    }

    @Test("the menu enumerates a production-realistic destination count")
    func destinations() {
        // 4 — the user's measured real library. Both `Menu`s enumerate this list, so
        // menu cost scales linearly in it and is paid twice per cell.
        #expect(BakeoffCellFidelity.moveTargets.all.count
            == BakeoffCellFidelity.destinationCount)
        // Split across BOTH groups so production's divider between subfolders and
        // roots actually renders — a list from one group only would skip tree nodes
        // production builds.
        #expect(!BakeoffCellFidelity.moveTargets.subfolders.isEmpty)
        #expect(!BakeoffCellFidelity.moveTargets.roots.isEmpty)
    }
}
