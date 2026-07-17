//
//  NavModelTests.swift
//  AtelierRefsTests
//
//  004-P1 — the pure breadcrumb helper + the route-intent reducer. The
//  breadcrumb math is SwiftUI-free, tested directly (the GridNavigation pattern);
//  the NavModel intents are exercised on the main actor.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Nav: breadcrumb ancestor chain")
struct NavBreadcrumbTests {

    private func collection(_ id: UUID, name: String, parent: UUID? = nil) -> Collection {
        Collection(id: id, name: name, createdAt: Date(), updatedAt: Date(), parentCollectionID: parent)
    }

    @Test("root→leaf chain for a nested collection")
    func nestedChain() {
        let root = UUID(), mid = UUID(), leaf = UUID()
        let collections = [
            collection(root, name: "Root"),
            collection(mid, name: "Mid", parent: root),
            collection(leaf, name: "Leaf", parent: mid),
        ]
        let chain = collectionBreadcrumb(for: leaf, in: collections).map(\.name)
        #expect(chain == ["Root", "Mid", "Leaf"])
    }

    @Test("a root collection is its own single-element chain")
    func rootOnly() {
        let root = UUID()
        let chain = collectionBreadcrumb(for: root, in: [collection(root, name: "Root")])
        #expect(chain.map(\.name) == ["Root"])
    }

    @Test("an unknown id yields an empty chain")
    func unknown() {
        let chain = collectionBreadcrumb(for: UUID(), in: [collection(UUID(), name: "X")])
        #expect(chain.isEmpty)
    }

    @Test("a parent cycle terminates instead of hanging")
    func cycleSafe() {
        // a → b → a (corrupt). The walk must stop, not loop forever.
        let a = UUID(), b = UUID()
        let collections = [
            collection(a, name: "A", parent: b),
            collection(b, name: "B", parent: a),
        ]
        let chain = collectionBreadcrumb(for: a, in: collections)
        // Terminates; contains at most the two distinct nodes.
        #expect(chain.count <= 2)
        #expect(chain.last?.name == "A")
    }
}

@MainActor
@Suite("Nav: route intents")
struct NavRouteTests {

    @Test("openCollection / openSpace push; goBack pops; goToRoot clears")
    func pushPop() {
        let nav = NavModel(initialPath: [])
        let c = UUID(), s = UUID()
        nav.openCollection(c)
        #expect(nav.path == [.collection(c)])
        nav.openSpace(s)
        #expect(nav.path == [.collection(c), .space(s)])
        nav.goBack()
        #expect(nav.path == [.collection(c)])
        nav.goToRoot()
        #expect(nav.path.isEmpty)
    }

    @Test("pushing the same route twice is idempotent")
    func idempotentPush() {
        let nav = NavModel(initialPath: [])
        let c = UUID()
        nav.openCollection(c)
        nav.openCollection(c)
        #expect(nav.path == [.collection(c)])
        nav.openSpaces()
        nav.openSpaces()
        #expect(nav.path == [.collection(c), .spaces])
    }

    @Test("goBack at the root gallery is a no-op")
    func backAtRoot() {
        let nav = NavModel(initialPath: [])
        nav.goBack()
        #expect(nav.path.isEmpty)
    }
}
