//
//  CollectionFeedTests.swift
//  AtelierBrowseTests
//
//  098 · finding 9 — the feed's generation guard, which had never run under the condition
//  it exists for.
//
//  The guard's whole subject is a race: two loads in flight, finishing in the wrong order.
//  Against a real library both finish in microseconds and in the order they were started,
//  so no arrangement of a seeded database asks the question. `load(_:)` therefore takes
//  the read as a closure — the same shape `InboxDrainPolicy` takes its pass in, and for
//  the same reason — and the tests park the first read on a `Gate`. Nothing here sleeps.
//
//  The interleaving is not hypothetical. `CollectionScreen`'s `.task(id:)` re-keys on the
//  collection id AND on the store's ingest counter, so a drain pass landing while the user
//  switches collections starts a second load under a first one that is still reading. What
//  a stale answer would look like on screen is the previous collection's items under the
//  new collection's title, which is the bug `IngestionModel.loadContents(of:)` carries the
//  same guard against.
//

import Foundation
import Testing

import AtelierCaptureTestSupport
import AtelierCore
@testable import AtelierBrowse

@Suite("CollectionFeed (098 · 9)")
@MainActor
struct CollectionFeedTests {

    // MARK: - The ordinary path

    @Test("a load fills in the name, the items and the children")
    func loadsAScreen() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }
        let store = try await Self.store(over: fixture)

        let parent = try await fixture.services.createCollection(name: "Refs")
        let child = try await fixture.services.createCollection(name: "Type", parent: parent.id)
        let result = try await fixture.services.ingest(
            AssetDraft(
                kind: .image, blobHash: String(repeating: "2", count: 64),
                mimeType: "image/jpeg", width: 8, height: 8, fileSize: 3,
                downloadState: .downloaded),
            from: SourceDraft(
                platform: .web, originalURL: "https://example.com/a", capturedAt: Date()),
            into: parent.id)

        let feed = CollectionFeed()
        #expect(!feed.hasLoaded)
        await feed.load(parent.id, from: store)

        #expect(feed.hasLoaded)
        #expect(feed.name == "Refs")
        #expect(feed.items.map(\.asset.id) == [result.asset.id])
        #expect(feed.subcollections.map(\.id) == [child.id])
        #expect(feed.error == nil)
    }

    @Test("a load of a collection that is gone becomes the screen's sentence")
    func loadFails() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }
        let store = try await Self.store(over: fixture)

        let feed = CollectionFeed()
        await feed.load(UUID(), from: store)

        #expect(feed.hasLoaded)
        #expect(feed.error == "That collection is no longer in the library.")
        #expect(feed.items.isEmpty)
    }

    @Test("a successful load clears a previous error")
    func successClearsAnError() async throws {
        let fixture = try TempBrowseLibrary()
        defer { fixture.cleanup() }
        let store = try await Self.store(over: fixture)

        let feed = CollectionFeed()
        await feed.load(UUID(), from: store)
        #expect(feed.error != nil)

        await feed.load(BrowseLibrary.rootCollectionID, from: store)
        #expect(feed.error == nil)
        #expect(feed.hasLoaded)
    }

    // MARK: - The generation guard

    @Test("a stale load that finishes last does not overwrite the newer one")
    func staleLoadLosesToTheNewerOne() async throws {
        let gate = Gate()
        let feed = CollectionFeed()

        // The first load parks INSIDE its read, holding the old collection's answer.
        let stale = Task { @MainActor in
            await feed.load {
                await gate.wait()
                return Self.feed(named: "Stale", items: 3)
            }
        }
        // Started, and suspended on the gate before the second load is issued — asserted
        // rather than assumed, because "the first one got going" is the premise of the
        // whole case.
        await Task.yield()

        await feed.load { Self.feed(named: "Current", items: 1) }
        #expect(feed.name == "Current")
        #expect(feed.items.count == 1)

        gate.open()
        await stale.value

        // The point: the stale read completed AFTER the current one and wrote nothing.
        #expect(feed.name == "Current")
        #expect(feed.items.count == 1)
    }

    @Test("a stale FAILURE does not blank a screen that has already loaded")
    func staleFailureDoesNotOverwrite() async throws {
        struct Gone: Error {}
        let gate = Gate()
        let feed = CollectionFeed()

        let stale = Task { @MainActor in
            await feed.load { () -> BrowseLibrary.Feed in
                await gate.wait()
                throw Gone()
            }
        }
        await Task.yield()

        await feed.load { Self.feed(named: "Current", items: 2) }
        gate.open()
        await stale.value

        // The failure arm has its own copy of the guard, and it is the one that matters
        // most: a screen showing content replaced by an error sentence is a worse outcome
        // than a screen showing slightly old content.
        #expect(feed.error == nil)
        #expect(feed.name == "Current")
        #expect(feed.items.count == 2)
    }

    @Test("a NEWER failure does replace an older success")
    func newerFailureWins() async throws {
        struct Gone: Error {}
        let feed = CollectionFeed()

        await feed.load { Self.feed(named: "First", items: 2) }
        await feed.load { throw Gone() }

        // Not a latch in the other direction either: the guard is about ORDER, not about
        // protecting content.
        #expect(feed.error == "The library couldn't be opened.")
        #expect(feed.hasLoaded)
    }

    @Test("the generation is claimed synchronously, before the first suspension")
    func generationIsClaimedOnEntry() async throws {
        let gate = Gate()
        let feed = CollectionFeed()

        // Three loads started against one parked read. Each bumps the generation as its
        // first statement, so all three of the earlier ones are stale by the time any of
        // them resumes — which is what makes "the last one started wins" true regardless
        // of what order the runtime resumes them in.
        var parked: [Task<Void, Never>] = []
        for index in 0 ..< 3 {
            parked.append(Task { @MainActor in
                await feed.load {
                    await gate.wait()
                    return Self.feed(named: "Parked \(index)", items: index)
                }
            })
            await Task.yield()
        }

        await feed.load { Self.feed(named: "Winner", items: 9) }
        gate.open()
        for task in parked { await task.value }

        #expect(feed.name == "Winner")
        #expect(feed.items.count == 9)
    }

    @Test("two feeds do not share a generation — one screen's load cannot cancel another's")
    func feedsAreIndependent() async throws {
        let root = CollectionFeed()
        let pushed = CollectionFeed()

        await root.load { Self.feed(named: "Unsorted", items: 4) }
        await pushed.load { Self.feed(named: "Concrete", items: 1) }

        // The reason there is one of these per screen at all: going Back must not find the
        // root showing the child's items.
        #expect(root.name == "Unsorted")
        #expect(root.items.count == 4)
        #expect(pushed.name == "Concrete")
    }

    // MARK: - Fixtures

    private static func store(over fixture: TempBrowseLibrary) async throws -> BrowseStore {
        let root = fixture.root
        let store = BrowseStore(root: { root })
        await store.bootstrap()
        return store
    }

    /// A feed with `items` synthetic memberships in one collection — enough shape for the
    /// ordering claims, and no database at all, which is the point of the closure seam.
    private static func feed(named name: String, items: Int) -> BrowseLibrary.Feed {
        let collection = Collection(
            id: UUID(), name: name, createdAt: Date(), updatedAt: Date())
        return BrowseLibrary.Feed(
            collection: collection,
            items: (0 ..< items).map { _ in detail(in: collection.id) },
            subcollections: [])
    }

    private static func detail(in collectionID: UUID) -> CollectionItemDetail {
        let sourceID = UUID()
        let assetID = UUID()
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: collectionID, assetID: assetID,
                addedAt: Date(), manualOrder: 0),
            asset: Asset(
                id: assetID, kind: .image, blobHash: String(repeating: "3", count: 64),
                mimeType: "image/jpeg", width: 4, height: 4, fileSize: 1,
                downloadState: .downloaded, createdAt: Date(), sourceId: sourceID),
            source: Source(
                id: sourceID, platform: .web, originalURL: "https://example.com/x",
                capturedAt: Date()))
    }
}
