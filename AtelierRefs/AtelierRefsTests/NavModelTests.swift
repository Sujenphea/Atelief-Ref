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

    /// **Leaving the pane closes its item detail** (355). Home / Capture / a Space are
    /// separate arms of the shell's `switch`, so the collection pane unmounts and the
    /// overlay's host goes with it — none of its observers run. A route left pointing at
    /// an item nothing is showing kept the sidebar collapsed, hid the pane's floating +,
    /// and told the grid the page still owned the keyboard, so the grid answered no key
    /// on return until an item had been opened and closed.
    @Test("selecting a sidebar destination drops the presented item")
    func sidebarSelectionClearsDetail() {
        let nav = NavModel(initialPath: [])
        nav.presentedItemID = UUID()
        nav.selectSidebar(.home)
        #expect(nav.presentedItemID == nil)

        nav.presentedItemID = UUID()
        nav.openCollection(UUID())
        #expect(nav.presentedItemID == nil)

        nav.presentedItemID = UUID()
        nav.openSpace(UUID())
        #expect(nav.presentedItemID == nil)
    }

    /// ⌘[ pops a drill-down, which unmounts the pane the same way.
    @Test("goBack drops the presented item; a no-op back leaves it alone")
    func backClearsDetail() {
        let nav = NavModel(initialPath: [])
        nav.drillIntoCollection(UUID())
        let shown = UUID()
        nav.presentedItemID = shown
        nav.goBack()
        #expect(nav.presentedItemID == nil)

        // At the root there is nothing to pop, so nothing is torn down either.
        nav.presentedItemID = shown
        nav.goBack()
        #expect(nav.presentedItemID == shown)
    }

    /// A collection DELETED under an open page moves the route through `reconcile`
    /// rather than `selectSidebar`, and unmounts the pane just the same — but a
    /// reconcile that moves nothing runs on every folder refresh, and must leave a live
    /// page alone.
    @Test("reconcile drops the presented item only when the route actually moves")
    func reconcileClearsDetailOnlyWhenRouteMoves() {
        let epoch = Date(timeIntervalSince1970: 0)
        let live = UUID(), gone = UUID()
        let collections = [Collection(
            id: live, name: "c", createdAt: epoch, updatedAt: epoch, parentCollectionID: nil)]

        // Still there → the page survives an ordinary refresh.
        let nav = NavModel(initialPath: [], initialSelection: .collection(live))
        let shown = UUID()
        nav.presentedItemID = shown
        nav.reconcile(using: collections)
        #expect(nav.presentedItemID == shown)
        #expect(nav.sidebarSelection == .collection(live))

        // Deleted → falls back to Home, and the page goes with it.
        let orphaned = NavModel(initialPath: [], initialSelection: .collection(gone))
        orphaned.presentedItemID = UUID()
        orphaned.reconcile(using: collections)
        #expect(orphaned.sidebarSelection == .home)
        #expect(orphaned.presentedItemID == nil)
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
