//
//  FolderAccessTests.swift
//  AtelierRefsTests
//
//  008 · F2 — the persistence, staleness, and failure behaviour of the chosen
//  backup folder, driven through a fake `BookmarkVault` so none of it needs the
//  sandbox (a test process can't obtain a powerbox-granted URL, which is exactly
//  why that seam exists).
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("FolderAccess (008 F2)")
struct FolderAccessTests {

    /// Records calls and can be told to fail or report staleness.
    final class FakeVault: BookmarkVault, @unchecked Sendable {
        enum Mode { case ok, stale, unresolvable, makeFails }
        var mode: Mode
        var resolvedURL: URL
        private(set) var makeCount = 0
        private(set) var resolveCount = 0

        init(mode: Mode = .ok, resolvedURL: URL = URL(fileURLWithPath: "/tmp/backup-target")) {
            self.mode = mode
            self.resolvedURL = resolvedURL
        }

        struct Failure: Error {}

        func makeBookmark(for url: URL) throws -> Data {
            makeCount += 1
            if mode == .makeFails { throw Failure() }
            return Data(url.path.utf8)
        }

        func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
            resolveCount += 1
            switch mode {
            case .unresolvable: throw Failure()
            case .stale: return (resolvedURL, true)
            default: return (resolvedURL, false)
            }
        }
    }

    /// An isolated defaults suite per test — never touches the real domain.
    private func makeDefaults() -> UserDefaults {
        let name = "FolderAccessTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("no folder chosen: hasFolder is false and resolve throws .noFolderChosen")
    func noFolderChosen() throws {
        let access = StoredFolderAccess(vault: FakeVault(), defaults: makeDefaults())
        #expect(!access.hasFolder)
        #expect(throws: FolderAccessError.noFolderChosen) { try access.resolve() }
    }

    @Test("setFolder persists a bookmark that resolves back on a later launch")
    func setThenResolveAcrossLaunches() throws {
        let defaults = makeDefaults()
        let target = URL(fileURLWithPath: "/Volumes/Backups/atelier")
        let vault = FakeVault(resolvedURL: target)

        let first = StoredFolderAccess(vault: vault, defaults: defaults)
        try first.setFolder(target)
        #expect(first.hasFolder)

        // A fresh instance over the same defaults = the next launch.
        let next = StoredFolderAccess(vault: vault, defaults: defaults)
        #expect(next.hasFolder)
        #expect(try next.resolve() == target)
    }

    @Test("a failed bookmark leaves NO target behind (never half-chosen)")
    func failedBookmarkPersistsNothing() throws {
        let defaults = makeDefaults()
        let access = StoredFolderAccess(
            vault: FakeVault(mode: .makeFails), defaults: defaults)

        #expect(throws: (any Error).self) {
            try access.setFolder(URL(fileURLWithPath: "/tmp/x"))
        }
        #expect(!access.hasFolder)
        #expect(throws: FolderAccessError.noFolderChosen) { try access.resolve() }
    }

    @Test("an unresolvable bookmark throws — and is KEPT, so re-plugging a drive works")
    func unresolvableKeepsTarget() throws {
        let defaults = makeDefaults()
        let vault = FakeVault()
        let access = StoredFolderAccess(vault: vault, defaults: defaults)
        try access.setFolder(URL(fileURLWithPath: "/Volumes/Ext/atelier"))

        vault.mode = .unresolvable // drive unplugged
        #expect(throws: FolderAccessError.bookmarkUnresolvable) { try access.resolve() }
        #expect(access.hasFolder) // not forgotten

        vault.mode = .ok // plugged back in
        #expect(try access.resolve() == vault.resolvedURL)
    }

    @Test("clearFolder forgets the target")
    func clearForgets() throws {
        let access = StoredFolderAccess(vault: FakeVault(), defaults: makeDefaults())
        try access.setFolder(URL(fileURLWithPath: "/tmp/x"))
        #expect(access.hasFolder)

        access.clearFolder()

        #expect(!access.hasFolder)
        #expect(throws: FolderAccessError.noFolderChosen) { try access.resolve() }
    }

    @Test("a stale bookmark still resolves and does not throw")
    func staleStillResolves() throws {
        let moved = URL(fileURLWithPath: "/Volumes/Backups/moved")
        let vault = FakeVault(mode: .stale, resolvedURL: moved)
        let access = StoredFolderAccess(vault: vault, defaults: makeDefaults())
        try access.setFolder(URL(fileURLWithPath: "/Volumes/Backups/original"))

        // Staleness is the OS asking for a rewrite, not a failure: the caller
        // gets a usable URL. (The refresh itself needs a real security scope,
        // which this process can't hold — it is best-effort by construction.)
        #expect(try access.resolve() == moved)
    }

    @Test("DirectFolderAccess passes a plain directory straight through")
    func directAccess() throws {
        let dir = URL(fileURLWithPath: "/tmp/plain")
        let access = DirectFolderAccess(url: dir)

        #expect(try access.resolve() == dir)
        let name = try access.withAccess { $0.lastPathComponent }
        #expect(name == "plain")
    }

    @Test("DirectFolderAccess releases correctly when the body throws")
    func directAccessPropagatesThrow() throws {
        struct Boom: Error {}
        let access = DirectFolderAccess(url: URL(fileURLWithPath: "/tmp/plain"))
        #expect(throws: Boom.self) {
            try access.withAccess { _ in throw Boom() }
        }
    }
}
