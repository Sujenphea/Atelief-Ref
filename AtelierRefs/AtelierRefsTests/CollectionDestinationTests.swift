//
//  CollectionDestinationTests.swift
//  AtelierRefsTests
//
//  026 · I1 / 027 · G2 — the ONE destination ordering and its TWO renderers.
//
//  Neither renderer can be clicked from a unit test (an `NSMenu` needs a
//  right-click; the SwiftUI list needs a popover), so every decision either one
//  makes is kept in a pure function and asserted here:
//
//   • the nested-menu builder — depth, ordering, the greyed current collection,
//     and the "here" row injected ONLY where a row has children;
//   • the indented list's rows — depth, Unsorted first, member exclusion;
//   • and a CONTRACT test that the two produce the same destinations in the same
//     order, which is what makes "one ordering, two renderers" a fact rather than
//     an intention. The bug this replaces was precisely a second, narrower
//     ordering living in the grid menu.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Collection destinations — one ordering, two renderers")
struct CollectionDestinationTests {

    private let unsortedID = Collection.unsortedID

    private func collection(
        _ name: String, id: UUID = UUID(), parent: UUID? = nil, sortIndex: Int = 0
    ) -> Collection {
        Collection(
            id: id, name: name, description: nil, coverAssetID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            parentCollectionID: parent, sortIndex: sortIndex)
    }

    /// The fixture 027 §A is written against:
    ///
    ///     Unsorted
    ///     Refs ▸ Type ▸ Serif, Sans
    ///     Photography ▸ Portraits
    private struct Fixture {
        let unsorted: Collection, refs: Collection, type: Collection
        let serif: Collection, sans: Collection
        let photography: Collection, portraits: Collection
        var all: [Collection] {
            [unsorted, refs, type, serif, sans, photography, portraits]
        }
    }

    private func fixture() -> Fixture {
        let unsorted = collection("Unsorted", id: unsortedID)
        let refs = collection("Refs", sortIndex: 0)
        let type = collection("Type", parent: refs.id)
        let serif = collection("Serif", parent: type.id, sortIndex: 0)
        let sans = collection("Sans", parent: type.id, sortIndex: 1)
        let photography = collection("Photography", sortIndex: 1)
        let portraits = collection("Portraits", parent: photography.id)
        return Fixture(
            unsorted: unsorted, refs: refs, type: type, serif: serif, sans: sans,
            photography: photography, portraits: portraits)
    }

    private func items(
        _ folders: [Collection], disabled: Set<UUID> = [],
        verb: CollectionDestinationMenu.Verb = .move
    ) -> [DestinationMenuItem] {
        CollectionDestinationMenu.items(
            folders: folders, unsortedID: unsortedID, disabled: disabled, verb: verb)
    }

    // MARK: - The nested menu builder

    @Test("the menu nests the whole hierarchy — a third-level folder is reachable")
    func nestsTheWholeTree() {
        let f = fixture()
        let rows = items(f.all)

        // Root level: Unsorted, a separator, then the two parents as submenus.
        #expect(rows.count == 4)
        #expect(rows[0] == .destination(id: f.unsorted.id, title: "Unsorted", isEnabled: true))
        #expect(rows[1] == .separator)

        guard case let .submenu(refsID, refsTitle, refsItems) = rows[2] else {
            Issue.record("Refs should carry a submenu"); return
        }
        #expect(refsID == f.refs.id)
        #expect(refsTitle == "Refs")

        // Refs ▸ Move here, ─────, Type ▸ …
        #expect(refsItems[0] == .destination(id: f.refs.id, title: "Move here", isEnabled: true))
        #expect(refsItems[1] == .separator)
        guard case let .submenu(typeID, typeTitle, typeItems) = refsItems[2] else {
            Issue.record("Type should carry a submenu"); return
        }
        #expect(typeID == f.type.id)
        #expect(typeTitle == "Type")

        // …and the third level — the folders the old flat `moveTargets` could not
        // reach from anywhere, at any depth.
        #expect(typeItems == [
            .destination(id: f.type.id, title: "Move here", isEnabled: true),
            .separator,
            .destination(id: f.serif.id, title: "Serif", isEnabled: true),
            .destination(id: f.sans.id, title: "Sans", isEnabled: true),
        ])
    }

    @Test("a \"here\" row is injected ONLY where the row has children")
    func hereRowOnlyOnParents() {
        let f = fixture()
        // Every leaf is a plain destination; every parent's first row is the verb.
        func check(_ rows: [DestinationMenuItem]) {
            for row in rows {
                if case let .submenu(id, _, children) = row {
                    #expect(children.first == .destination(
                        id: id, title: "Move here", isEnabled: true))
                    #expect(children.dropFirst().first == .separator)
                    check(Array(children.dropFirst(2)))
                }
            }
        }
        let rows = items(f.all)
        check(rows)

        // Exactly the three parents carry a "here" row — Refs, Type, Photography —
        // and none of the four leaves does.
        #expect(countHereRows(items(f.all)) == 3)
        #expect(countLeafRows(items(f.all)) == 4)   // Unsorted, Serif, Sans, Portraits
    }

    @Test("the \"here\" row names the CALLER's verb, not always \"Move\"")
    func hereRowFollowsTheVerb() {
        let f = fixture()
        guard case let .submenu(_, _, refsItems) = items(f.all, verb: .add)[2] else {
            Issue.record("Refs should carry a submenu"); return
        }
        #expect(refsItems[0] == .destination(id: f.refs.id, title: "Add here", isEnabled: true))
    }

    @Test("the current collection is PRESENT and disabled, at every level")
    func currentCollectionIsGreyedNotOmitted() {
        let f = fixture()
        // Disabling a nested parent: the row still opens (its children are valid
        // destinations) but its own "here" row is greyed.
        let rows = items(f.all, disabled: [f.type.id, f.portraits.id])

        guard case let .submenu(_, _, refsItems) = rows[2],
              case let .submenu(_, _, typeItems) = refsItems[2] else {
            Issue.record("expected Refs ▸ Type"); return
        }
        #expect(typeItems[0] == .destination(id: f.type.id, title: "Move here", isEnabled: false))
        // Its children stay enabled — nesting under the current collection is a
        // real move.
        #expect(typeItems[2] == .destination(id: f.serif.id, title: "Serif", isEnabled: true))

        // A disabled LEAF is still listed, greyed.
        guard case let .submenu(_, _, photoItems) = rows[3] else {
            Issue.record("expected Photography ▸"); return
        }
        #expect(photoItems.contains(
            .destination(id: f.portraits.id, title: "Portraits", isEnabled: false)))
        #expect(CollectionDestinationMenu.destinationIDs(rows).contains(f.type.id))
    }

    @Test("Unsorted is pinned first and separated from the user's own folders")
    func unsortedPinnedAndSeparated() {
        let f = fixture()
        let rows = items(f.all)
        #expect(CollectionDestinationMenu.destinationIDs(rows).first == unsortedID)
        #expect(rows[1] == .separator)
    }

    @Test("a library of ONLY Unsorted gets no dangling separator")
    func loneUnsortedHasNoSeparator() {
        let unsorted = collection("Unsorted", id: unsortedID)
        #expect(items([unsorted]) == [
            .destination(id: unsortedID, title: "Unsorted", isEnabled: true),
        ])
    }

    @Test("an empty library yields an empty menu")
    func emptyLibrary() {
        #expect(items([]).isEmpty)
    }

    @Test("a 6-deep chain makes a 6-deep submenu chain — the depth is never capped")
    func sixDeepChainIsNotTruncated() {
        var folders = [collection("Unsorted", id: unsortedID)]
        var parent: UUID?
        var ids: [UUID] = []
        for level in 0..<6 {
            let c = collection("L\(level)", parent: parent)
            folders.append(c)
            ids.append(c.id)
            parent = c.id
        }

        // Walk the chain: L0…L4 are submenus (each with a "here" row), L5 a leaf.
        var rows = items(folders)
        for level in 0..<5 {
            guard case let .submenu(id, title, children) = rows.last else {
                Issue.record("L\(level) should carry a submenu"); return
            }
            #expect(id == ids[level])
            #expect(title == "L\(level)")
            #expect(children[0] == .destination(id: ids[level], title: "Move here", isEnabled: true))
            rows = Array(children.dropFirst(2))
        }
        #expect(rows == [.destination(id: ids[5], title: "L5", isEnabled: true)])
    }

    // MARK: - The indented list (026 · I1)

    @Test("the list indents by depth, Unsorted first")
    func listRowsIndentByDepth() {
        let f = fixture()
        let rows = CollectionDestinationList.rows(folders: f.all, unsortedID: unsortedID)

        #expect(rows.map(\.collection.name)
            == ["Unsorted", "Refs", "Type", "Serif", "Sans", "Photography", "Portraits"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 2, 0, 1])
    }

    @Test("the detail page's already-member collections are excluded")
    func listExcludesExistingMemberships() {
        let f = fixture()
        let rows = CollectionDestinationList.rows(
            folders: f.all, unsortedID: unsortedID,
            excluded: [f.unsorted.id, f.type.id])

        #expect(rows.map(\.collection.name)
            == ["Refs", "Serif", "Sans", "Photography", "Portraits"])
        // An excluded PARENT leaves its children at their original depth — the
        // indentation still says where `Serif` lives.
        #expect(rows.map(\.depth) == [0, 2, 2, 0, 1])
    }

    @Test("excluding everything leaves an empty list (the \"No other collections\" state)")
    func listEmptyWhenEverythingIsExcluded() {
        let f = fixture()
        let rows = CollectionDestinationList.rows(
            folders: f.all, unsortedID: unsortedID, excluded: Set(f.all.map(\.id)))
        #expect(rows.isEmpty)
    }

    @Test("an empty library leaves an empty list")
    func listEmptyLibrary() {
        #expect(CollectionDestinationList.rows(folders: [], unsortedID: unsortedID).isEmpty)
    }

    // MARK: - The contract: one ordering, two renderers

    @Test("the nested menu and the indented list offer the SAME destinations in the SAME order")
    func renderersShareOneOrdering() {
        let f = fixture()
        let menuIDs = CollectionDestinationMenu.destinationIDs(items(f.all))
        let listIDs = CollectionDestinationList.rows(
            folders: f.all, unsortedID: unsortedID).map(\.id)

        #expect(menuIDs == listIDs)
        #expect(menuIDs == [
            f.unsorted.id, f.refs.id, f.type.id, f.serif.id, f.sans.id,
            f.photography.id, f.portraits.id,
        ])
    }

    @Test("the two renderers disable the same set")
    func renderersShareTheDisabledSet() {
        let f = fixture()
        let disabled: Set<UUID> = [f.refs.id, f.sans.id]

        let menuDisabled = disabledIDs(items(f.all, disabled: disabled))
        let listDisabled = Set(
            CollectionDestinationList.rows(folders: f.all, unsortedID: unsortedID)
                .map(\.id)
                .filter { disabled.contains($0) })

        #expect(menuDisabled == disabled)
        #expect(menuDisabled == listDisabled)
    }

    @Test("the contract holds for a 6-deep chain too")
    func renderersAgreeOnADeepTree() {
        var folders = [collection("Unsorted", id: unsortedID)]
        var parent: UUID?
        for level in 0..<6 {
            let c = collection("L\(level)", parent: parent)
            folders.append(c)
            parent = c.id
        }

        #expect(
            CollectionDestinationMenu.destinationIDs(items(folders))
                == CollectionDestinationList.rows(
                    folders: folders, unsortedID: unsortedID).map(\.id))
    }

    // MARK: - Helpers

    private func countHereRows(_ items: [DestinationMenuItem]) -> Int {
        items.reduce(0) { total, item in
            if case let .submenu(_, _, children) = item {
                return total + 1 + countHereRows(Array(children.dropFirst(2)))
            }
            return total
        }
    }

    private func countLeafRows(_ items: [DestinationMenuItem]) -> Int {
        items.reduce(0) { total, item in
            switch item {
            case .destination: total + 1
            case .separator: total
            case let .submenu(_, _, children): total + countLeafRows(Array(children.dropFirst(2)))
            }
        }
    }

    private func disabledIDs(_ items: [DestinationMenuItem]) -> Set<UUID> {
        items.reduce(into: Set<UUID>()) { out, item in
            switch item {
            case .separator:
                break
            case let .destination(id, _, isEnabled):
                if !isEnabled { out.insert(id) }
            case let .submenu(_, _, children):
                out.formUnion(disabledIDs(children))
            }
        }
    }
}

/// 027 · G2's performance clause. `MoveTargetsCache` exists because the SwiftUI
/// context menu used to build EAGERLY per visible cell at ~326ms/pass (012 · CQ
/// 1A). The native menu now nests lazily on right-click, but the grid
/// configuration still carries the tree as a value on every body pass, so the memo
/// is what keeps the grouping + per-parent sorts off the render (and therefore the
/// scroll) path. A recursive build is more work per invocation than the flat one
/// it replaced, hence the re-measurement.
@Suite("Destination tree build cost")
@MainActor
struct CollectionDestinationPerfTests {

    private static let unsortedID = Collection.unsortedID

    /// 40 folders, 4 levels deep — the fixture 027's perf clause names.
    private static func library() -> [Collection] {
        func make(_ name: String, parent: UUID?, sortIndex: Int) -> Collection {
            Collection(
                id: UUID(), name: name, description: nil, coverAssetID: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                parentCollectionID: parent, sortIndex: sortIndex)
        }
        var folders = [make("Unsorted", parent: nil, sortIndex: 0)]
        folders[0].id = unsortedID
        // 3 roots × 3 children × 3 grandchildren × ~1 great-grandchild ≈ 40 rows.
        var level1: [UUID] = []
        for i in 0..<3 {
            let root = make("Root \(i)", parent: nil, sortIndex: i)
            folders.append(root)
            level1.append(root.id)
        }
        var level2: [UUID] = []
        for (i, parent) in level1.enumerated() {
            for j in 0..<3 {
                let c = make("Sub \(i)-\(j)", parent: parent, sortIndex: j)
                folders.append(c)
                level2.append(c.id)
            }
        }
        var level3: [UUID] = []
        for (i, parent) in level2.enumerated() {
            for j in 0..<2 {
                let c = make("Leaf \(i)-\(j)", parent: parent, sortIndex: j)
                folders.append(c)
                level3.append(c.id)
            }
        }
        for (i, parent) in level3.prefix(9).enumerated() {
            folders.append(make("Deep \(i)", parent: parent, sortIndex: 0))
        }
        return folders
    }

    @Test("the memo hits across renders — one build per folder-tree change")
    func cacheHitsAcrossRenders() {
        let folders = Self.library()
        let cache = MoveTargetsCache()

        // 200 body passes with an unchanged folder tree: ONE build. This is the
        // "not called during scroll" assertion — a scroll re-renders the host
        // without touching `model.folders`, so every pass after the first is a hit.
        for _ in 0..<200 {
            _ = cache.destinationTree(folders: folders, unsortedID: Self.unsortedID)
        }
        #expect(cache.buildCount == 1)

        // A real folder edit invalidates it exactly once, then hits again.
        var edited = folders
        edited[5].name = "Renamed"
        for _ in 0..<200 {
            _ = cache.destinationTree(folders: edited, unsortedID: Self.unsortedID)
        }
        #expect(cache.buildCount == 2)
    }

    @Test("a cold build over a 40-folder, 4-deep library costs far less than a frame")
    func coldBuildIsCheap() {
        let folders = Self.library()
        #expect(folders.count >= 40)

        // 100 cold builds + menu materialization, the whole per-right-click cost.
        let start = Date()
        var rows = 0
        for _ in 0..<100 {
            let tree = CollectionTargets.destinationTree(
                folders: folders, unsortedID: Self.unsortedID)
            rows += CollectionDestinationMenu.items(
                tree: tree, unsortedID: Self.unsortedID, verb: .move).count
        }
        let perBuildMS = Date().timeIntervalSince(start) * 1000 / 100
        #expect(rows > 0)

        // Measured at 0.157ms on this machine (Debug, -Onone, arm64). The bound is
        // deliberately ~30× that — the point is the ORDER, not the number: this is
        // a sixth of a millisecond, so the old eager-per-cell hazard (~326ms/pass)
        // cannot come back through the recursive build.
        #expect(perBuildMS < 5, "cold destination build took \(perBuildMS)ms")
    }
}
