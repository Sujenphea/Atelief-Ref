//
//  NavModelTests.swift
//  AtelierRefsTests
//
//  004-P1 — the route-intent reducer, exercised on the main actor. (The pure
//  breadcrumb helper this file also covered was retired with the 043 breadcrumb
//  UI removal.)
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Nav: route intents")
struct NavRouteTests {

    @Test("openCollection / openSpace select the sidebar destination + clear drill-down")
    func sidebarSelection() {
        let nav = NavModel(initialPath: [])
        let c = UUID(), s = UUID()
        nav.drillIntoCollection(UUID())          // seed some drill-down
        nav.openCollection(c)
        #expect(nav.sidebarSelection == .collection(c))
        #expect(nav.path.isEmpty)                // a sidebar selection resets path
        nav.openSpace(s)
        #expect(nav.sidebarSelection == .space(s))
        #expect(nav.path.isEmpty)
    }

    @Test("drillIntoCollection pushes; idempotent; goBack pops; goToRoot clears")
    func drillPushPop() {
        let nav = NavModel(initialPath: [])
        let a = UUID(), b = UUID()
        nav.drillIntoCollection(a)
        nav.drillIntoCollection(a)               // same id twice is idempotent
        #expect(nav.path == [.collection(a)])
        nav.drillIntoCollection(b)
        #expect(nav.path == [.collection(a), .collection(b)])
        nav.goBack()
        #expect(nav.path == [.collection(a)])
        nav.goToRoot()
        #expect(nav.path.isEmpty)
    }

    @Test("goBack at the root gallery is a no-op")
    func backAtRoot() {
        let nav = NavModel(initialPath: [])
        nav.goBack()
        #expect(nav.path.isEmpty)
    }
}

/// The pure route-reconcile core (043 · 3A / 11A) — truncate a drill-down at the
/// first deleted collection; fall a deleted sidebar collection back to Home.
@Suite("Nav: reconcile against live collections")
struct NavReconcileTests {

    private func collection(_ id: UUID, parent: UUID? = nil) -> Collection {
        let epoch = Date(timeIntervalSince1970: 0)
        return Collection(
            id: id, name: "c", createdAt: epoch, updatedAt: epoch, parentCollectionID: parent)
    }

    @Test("nothing missing → identity (no launch-time mutation)")
    func noOpWhenPresent() {
        let a = UUID(), b = UUID()
        let r = NavModel.reconciled(
            selection: .collection(a),
            path: [.collection(b)],
            existing: Set([a, b]))
        #expect(r.selection == .collection(a))
        #expect(r.path == [.collection(b)])
    }

    @Test("deleted sidebar collection falls back to Home")
    func deletedSelectionToHome() {
        let a = UUID()
        let r = NavModel.reconciled(selection: .collection(a), path: [], existing: Set([UUID()]))
        #expect(r.selection == .home)
    }

    @Test("surviving sidebar collection is kept")
    func survivingSelectionKept() {
        let a = UUID()
        let r = NavModel.reconciled(selection: .collection(a), path: [], existing: Set([a]))
        #expect(r.selection == .collection(a))
    }

    @Test("path truncates AT the first deleted entry, dropping everything deeper")
    func pathTruncatesAtGap() {
        let a = UUID(), gone = UUID(), c = UUID()
        let r = NavModel.reconciled(
            selection: .home,
            path: [.collection(a), .collection(gone), .collection(c)],
            existing: Set([a, c]))              // `gone` deleted; `c` survives elsewhere
        #expect(r.path == [.collection(a)])     // `a` kept, `gone` + everything after dropped
    }

    @Test("a deleted entry deep in the path keeps the valid prefix")
    func pathKeepsValidPrefix() {
        let a = UUID(), b = UUID(), gone = UUID()
        let r = NavModel.reconciled(
            selection: .home,
            path: [.collection(a), .collection(b), .collection(gone)],
            existing: Set([a, b]))
        #expect(r.path == [.collection(a), .collection(b)])
    }

    @Test("non-collection routes are left untouched")
    func nonCollectionRoutesUntouched() {
        let s = UUID(), t = UUID()
        let r = NavModel.reconciled(
            selection: .capture,
            path: [.space(s), .space(t)],
            existing: Set([UUID()]))            // no collections referenced
        #expect(r.selection == .capture)
        #expect(r.path == [.space(s), .space(t)])
    }

    @Test("a space drill-down survives a sibling collection deletion")
    func spaceRouteSurvivesCollectionGap() {
        let s = UUID(), gone = UUID()
        let r = NavModel.reconciled(
            selection: .space(s),
            path: [.space(s)],
            existing: Set([UUID()]))            // `gone` never in `existing`, but unreferenced
        #expect(r.selection == .space(s))
        #expect(r.path == [.space(s)])
        _ = gone
    }

    @MainActor
    @Test("reconcile(using:) is a no-op on an empty (not-yet-loaded) folder list")
    func emptyListSkipped() {
        let a = UUID()
        let nav = NavModel(initialSelection: .collection(a))
        nav.reconcile(using: [])                // folders not loaded yet
        #expect(nav.sidebarSelection == .collection(a))
    }

    @MainActor
    @Test("reconcile(using:) applies fallback + truncation to the live model")
    func appliesToModel() {
        let a = UUID(), gone = UUID()
        let nav = NavModel(initialPath: [.collection(gone)], initialSelection: .collection(gone))
        nav.reconcile(using: [collection(a)])
        #expect(nav.sidebarSelection == .home)
        #expect(nav.path.isEmpty)
    }
}
