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
