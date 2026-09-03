//
//  SwitcherRecentsTests.swift
//  AtelierRefsTests
//
//  099 · P5 — the ⌘K MRU: the key it is stored under, and the four rules of the
//  list itself.
//
//  The KEY SHAPE is asserted as a literal string on purpose. `library.<id>.` is
//  016 §C's discipline — every per-library preference adopts the prefix now so
//  multi-library needs no migration later — and a prefix that is only a convention
//  is one the next preference gets wrong. `ClipboardWatcher.enabledKey(libraryID:)`
//  is the precedent this matched, and `keyMatchesTheClipboardPreferencesShape`
//  compares the two directly rather than restating the format.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("The ⌘K switcher's per-library MRU", .timeLimit(.minutes(1)))
struct SwitcherRecentsTests {

    /// A defaults suite of its own per test, so nothing here can read or write the
    /// developer's real preferences — `GridDensity`'s and `BackupCadence`'s pattern.
    private func makeDefaults(_ label: String) throws -> UserDefaults {
        let name = "switcher-recents-\(label)-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    // MARK: - The key

    @Test("the key is namespaced by library id, per 016 §C")
    func keyIsNamespacedByLibrary() {
        #expect(
            SwitcherRecents.defaultsKey(libraryID: "ABC123")
                == "library.ABC123.switcherRecents")
    }

    @Test("the key shape is the clipboard preference's, not a second invention")
    func keyMatchesTheClipboardPreferencesShape() {
        let id = "ABC123"
        let mine = SwitcherRecents.defaultsKey(libraryID: id)
        let precedent = ClipboardWatcher.enabledKey(libraryID: id)
        // Same prefix, different leaf. Compared against the other key rather than
        // against a format string, so the day someone changes the namespace they
        // have to change it in both places or fail here.
        let prefix = "library.\(id)."
        #expect(mine.hasPrefix(prefix))
        #expect(precedent.hasPrefix(prefix))
        #expect(mine != precedent)
    }

    // MARK: - Tokens

    @Test("every destination the switcher offers round-trips through a token")
    func tokensRoundTrip() {
        let collection = UUID()
        let space = UUID()
        let search = UUID()
        let destinations: [SidebarItem] = [
            .home, .capture, .shelf,
            .collection(collection), .space(space), .savedSearch(search),
        ]
        for destination in destinations {
            let token = SwitcherRecents.token(for: destination)
            #expect(token != nil, "\(destination) has no token")
            #expect(
                token.flatMap(SwitcherRecents.destination(forToken:)) == destination,
                "\(destination) did not survive its token")
        }
        // The spellings themselves, because they are PERSISTED: changing one
        // silently drops everyone's MRU rather than failing anything.
        #expect(SwitcherRecents.token(for: .home) == "home")
        #expect(SwitcherRecents.token(for: .capture) == "capture")
        #expect(SwitcherRecents.token(for: .shelf) == "shelf")
        #expect(
            SwitcherRecents.token(for: .collection(collection))
                == "collection:\(collection.uuidString)")
    }

    @Test("a token that does not parse is dropped rather than crashing a read")
    func unparsableTokensAreDropped() throws {
        #expect(SwitcherRecents.destination(forToken: "") == nil)
        #expect(SwitcherRecents.destination(forToken: "theme") == nil)
        #expect(SwitcherRecents.destination(forToken: "collection") == nil)
        #expect(SwitcherRecents.destination(forToken: "collection:not-a-uuid") == nil)
        #expect(SwitcherRecents.destination(forToken: "planet:\(UUID().uuidString)") == nil)

        // …and a stored list containing one still yields the rows that DO parse.
        let defaults = try makeDefaults("garbage")
        defaults.set(
            ["home", "collection:not-a-uuid", "shelf"],
            forKey: SwitcherRecents.defaultsKey(libraryID: "L"))
        let recents = SwitcherRecents(defaults: defaults)
        recents.activate(libraryID: "L")
        #expect(recents.destinations == [.home, .shelf])
    }

    // MARK: - The list

    @Test("a visit goes to the front, and a revisit moves rather than duplicates")
    func recordIsMostRecentFirstAndDeduplicates() throws {
        let defaults = try makeDefaults("order")
        let recents = SwitcherRecents(defaults: defaults)
        recents.activate(libraryID: "L")
        let a = SidebarItem.collection(UUID())
        let b = SidebarItem.space(UUID())

        recents.record(a)
        recents.record(b)
        #expect(recents.destinations == [b, a])
        recents.record(a)
        #expect(recents.destinations == [a, b])
    }

    @Test("the list is capped, and the oldest falls off the end")
    func recordIsCapped() throws {
        let defaults = try makeDefaults("cap")
        let recents = SwitcherRecents(defaults: defaults)
        recents.activate(libraryID: "L")
        let all = (0..<(SwitcherRecents.capacity + 3)).map { _ in SidebarItem.collection(UUID()) }
        for destination in all { recents.record(destination) }

        #expect(recents.destinations.count == SwitcherRecents.capacity)
        #expect(recents.destinations.first == all.last)
        #expect(!recents.destinations.contains(all[0]))
    }

    @Test("what was recorded is what comes back on the next launch")
    func activateReadsTheStoredList() throws {
        let defaults = try makeDefaults("persist")
        let first = SwitcherRecents(defaults: defaults)
        first.activate(libraryID: "L")
        let target = SidebarItem.savedSearch(UUID())
        first.record(target)
        first.record(.home)

        let second = SwitcherRecents(defaults: defaults)
        second.activate(libraryID: "L")
        #expect(second.destinations == [.home, target])
    }

    @Test("two libraries do not share a list")
    func twoLibrariesDoNotShareAList() throws {
        let defaults = try makeDefaults("two")
        let target = SidebarItem.collection(UUID())

        let one = SwitcherRecents(defaults: defaults)
        one.activate(libraryID: "one")
        one.record(target)

        let two = SwitcherRecents(defaults: defaults)
        two.activate(libraryID: "two")
        #expect(two.destinations.isEmpty)
    }

    @Test("nothing is recorded before the library id resolves")
    func recordBeforeActivateWritesNothing() throws {
        let defaults = try makeDefaults("early")
        let recents = SwitcherRecents(defaults: defaults)
        // The state between launch and `LibraryIdentity.resolve` — and the state a
        // library with a malformed `library-id` file stays in for the whole session.
        #expect(recents.libraryID == nil)
        recents.record(.home)
        #expect(recents.destinations.isEmpty)
        // Nothing was written under any key, un-namespaced ones included.
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy {
            !$0.contains("switcherRecents")
        })
    }
}
