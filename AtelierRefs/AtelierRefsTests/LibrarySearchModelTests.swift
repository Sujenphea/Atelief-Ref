//
//  LibrarySearchModelTests.swift
//  AtelierRefsTests
//
//  007 G2 — the search model's state machine (deterministic, no async query):
//  when a search is "active", when the scope toggle shows, and the default
//  scope a Collection screen adopts. The query itself is thin glue over the
//  G1-tested `searchAssets`; here we pin the surrounding logic.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("LibrarySearchModel state (007 G2)")
struct LibrarySearchModelTests {

    private func token(_ name: String, _ source: TagSource = .user) -> TagToken {
        TagToken(tag: Tag(id: UUID(), name: name, source: source))
    }

    @Test("isActive follows text and tokens")
    func isActive() {
        let m = LibrarySearchModel()
        #expect(!m.isActive)                      // empty
        m.text = "   "
        #expect(!m.isActive)                      // whitespace only
        m.text = "brass"
        #expect(m.isActive)
        m.text = ""
        m.tokens = [token("wood")]
        #expect(m.isActive)                       // a token alone activates
    }

    @Test("scope toggle only shows on a collection-scoped screen")
    func scopeToggle() {
        let global = LibrarySearchModel()
        global.configure(services: nil, collectionID: nil)
        #expect(!global.showsScopeToggle)

        let scoped = LibrarySearchModel()
        scoped.configure(services: nil, collectionID: UUID())
        #expect(scoped.showsScopeToggle)
    }

    @Test("a Collection screen defaults its scope to This Collection")
    func defaultScope() {
        let m = LibrarySearchModel()
        #expect(m.scope == .all)                  // fresh default
        m.configure(services: nil, collectionID: UUID())
        #expect(m.scope == .thisCollection)       // collection screen scopes to itself
    }

    @Test("configuring the global gallery leaves scope at All")
    func globalScopeStaysAll() {
        let m = LibrarySearchModel()
        m.configure(services: nil, collectionID: nil)
        #expect(m.scope == .all)
    }

    @Test("reset clears text, tokens, and results")
    func reset() {
        let m = LibrarySearchModel()
        m.text = "brass"; m.tokens = [token("wood")]
        m.reset()
        #expect(m.text.isEmpty)
        #expect(m.tokens.isEmpty)
        #expect(!m.isActive)
    }
}
