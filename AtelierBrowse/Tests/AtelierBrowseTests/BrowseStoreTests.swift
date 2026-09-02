//
//  BrowseStoreTests.swift
//  AtelierBrowseTests
//
//  098 · finding 9 — "Every line of the phone app target's logic is untested."
//
//  `BrowseStore` and `CollectionFeed` were `AtelierRefsMobile` files. Nothing in them
//  imports SwiftUI; what kept them in the app target was one call to
//  `LibraryLocation.resolvedRoot()` reading `CommandLine.arguments` and one debug fixture
//  seed. Both are injected now, and this file is what that bought:
//
//    · the bootstrap failure mapping, which is the ONLY thing a person sees when the App
//      Group is not granted, and which had never been executed;
//    · the feed's generation guard, whose whole reason for existing is an interleaving no
//      real library can be asked to produce on demand — here one read parks on a gate;
//    · the two `!=` guards (098 · finding 14), asserted through `withObservationTracking`,
//      which is the only honest way to say "this did not invalidate a view".
//
//  The library underneath is real and migrated, not a stub, for the reason
//  `BrowseLibraryTests` gives: a stub would prove that a stub returns what it was told to.
//

import Foundation
import Observation
import Synchronization
import Testing

import AtelierCaptureTestSupport
import AtelierCore
import AtelierLibraryPaths
@testable import AtelierBrowse

// MARK: - Harness

/// A `Bool` two isolation domains can agree on — the observation callbacks below are
/// `@Sendable` and fire synchronously inside a `willSet`.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// A throwaway root, and the store over it. `cleanup()` removes the whole directory.
@MainActor
private struct StoreRig {
    let root: URL
    let store: BrowseStore

    init(
        root overrideRoot: URL? = nil,
        prepare: BrowseStore.RootPreparation? = nil
    ) throws {
        root = try overrideRoot
            ?? InboxFixtures.temporaryLibraryRoot(suite: "AtelierBrowseStoreTests")
        let resolved = root
        store = BrowseStore(root: { resolved }, prepare: prepare)
    }

    /// A store whose root resolution FAILS — the App Group case, and the one the phone's
    /// error screen was written for.
    static func failing(_ error: Error) -> BrowseStore {
        BrowseStore(root: { throw error })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("BrowseStore (098 · 9)")
@MainActor
struct BrowseStoreTests {

    // MARK: - Bootstrap

    @Test("bootstrap opens the library, reads the tree and reports ready")
    func bootstrapSucceeds() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }

        #expect(rig.store.phase == .loading)
        await rig.store.bootstrap()

        #expect(rig.store.phase == .ready)
        #expect(rig.store.libraryRoot == rig.root)
        #expect(rig.store.services != nil)
        // Unsorted exists by migration, which is what makes the phone's opening screen
        // possible at all (093 § 2).
        #expect(rig.store.collections.contains { $0.id == BrowseLibrary.rootCollectionID })
        #expect(rig.store.rootCollectionID == BrowseLibrary.rootCollectionID)
    }

    @Test("bootstrap is idempotent — a re-run task does not open a second pool")
    func bootstrapIsIdempotent() async throws {
        let counted = Counter()
        let root = try InboxFixtures.temporaryLibraryRoot(suite: "AtelierBrowseStoreTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try StoreRig(root: root, prepare: { _ in counted.bump() })

        await rig.store.bootstrap()
        await rig.store.bootstrap()
        await rig.store.bootstrap()

        // The preparation is the observable proxy for "the whole bootstrap ran": it is the
        // first thing bootstrap does after resolving the root.
        #expect(counted.value == 1)
        #expect(rig.store.phase == .ready)
    }

    @Test("the preparation runs BEFORE the library is opened")
    func preparationRunsFirst() async throws {
        let root = try InboxFixtures.temporaryLibraryRoot(suite: "AtelierBrowseStoreTests")
        defer { try? FileManager.default.removeItem(at: root) }

        // What the debug fixture seed does: wipe the root and write a library into it. If
        // the store had opened its pool first, this removal would leave it reading a
        // deleted inode and the collection below would be invisible.
        let rig = try StoreRig(root: root, prepare: { root in
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let seeded = try AppServices.open(libraryRoot: root)
            _ = try await seeded.createCollection(name: "Seeded")
        })

        await rig.store.bootstrap()
        #expect(rig.store.phase == .ready)
        #expect(rig.store.collections.contains { $0.collection.name == "Seeded" })
    }

    // MARK: - Bootstrap failure, which is the whole of 093 § 7's ask

    @Test("a missing App Group identifier says it is a BUILD problem")
    func failedAppGroupIdentifier() async {
        let store = StoreRig.failing(
            LibraryLocationError.appGroupIdentifierMissing(key: "AtelierAppGroupIdentifier"))
        await store.bootstrap()
        #expect(store.phase
            == .failed("This build is missing its App Group. The library can't be opened."))
        #expect(store.libraryRoot == nil)
        #expect(store.services == nil)
    }

    @Test("an ungranted App Group container says the container is unavailable")
    func failedAppGroupContainer() async {
        let store = StoreRig.failing(
            LibraryLocationError.appGroupContainerUnavailable(identifier: "group.x"))
        await store.bootstrap()
        #expect(store.phase
            == .failed("The App Group container isn't available. The library can't be opened."))
    }

    @Test("any other resolution failure gets the general sentence")
    func failedForSomeOtherReason() async {
        struct Whatever: Error {}
        let store = StoreRig.failing(Whatever())
        await store.bootstrap()
        #expect(store.phase == .failed("The library couldn't be opened."))
    }

    @Test("a preparation that refuses fails the bootstrap rather than opening anyway")
    func failedPreparation() async throws {
        struct Refused: Error {}
        let root = try InboxFixtures.temporaryLibraryRoot(suite: "AtelierBrowseStoreTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try StoreRig(root: root, prepare: { _ in throw Refused() })

        await rig.store.bootstrap()
        #expect(rig.store.phase == .failed("The library couldn't be opened."))
        #expect(rig.store.services == nil)
    }

    @Test("a failed bootstrap can be retried — nothing latches")
    func failureIsNotALatch() async throws {
        let root = try InboxFixtures.temporaryLibraryRoot(suite: "AtelierBrowseStoreTests")
        defer { try? FileManager.default.removeItem(at: root) }
        struct Refused: Error {}
        let failFirst = Counter()
        let store = BrowseStore(root: { root }, prepare: { _ in
            if failFirst.bump() == 1 { throw Refused() }
        })

        await store.bootstrap()
        #expect(store.phase == .failed("The library couldn't be opened."))
        // The guard is `library == nil`, not `hasBootstrapped` — so a `task` that re-runs
        // after a transient failure gets a second chance rather than a permanent error.
        await store.bootstrap()
        #expect(store.phase == .ready)
    }

    @Test("reads before a successful bootstrap throw rather than returning nothing")
    func readsWithoutALibrary() async {
        struct Whatever: Error {}
        let store = StoreRig.failing(Whatever())
        await store.bootstrap()

        await #expect(throws: BrowseStore.LibraryUnavailable.self) {
            _ = try await store.feed(for: BrowseLibrary.rootCollectionID)
        }
        await #expect(throws: BrowseStore.LibraryUnavailable.self) {
            _ = try await store.item(UUID(), in: BrowseLibrary.rootCollectionID)
        }
        // The media resolvers answer `nil` rather than throwing: they are called from a
        // view body, per tile, and a throw there has nowhere to go.
        #expect(store.gridThumbnailURL(for: Self.asset()) == nil)
        #expect(store.detailImageURL(for: Self.asset()) == nil)
    }

    // MARK: - Ingest generation

    @Test("noteIngest moves the counter and nothing else")
    func noteIngest() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()

        let before = rig.store.collections
        #expect(rig.store.ingestGeneration == 0)
        rig.store.noteIngest()
        rig.store.noteIngest()
        #expect(rig.store.ingestGeneration == 2)
        // The screens re-read; the store does not do it for them.
        #expect(rig.store.collections == before)
    }

    // MARK: - The drain's one sentence (098 · P6)

    @Test("a drain notice arrives, is read, and is dismissed")
    func drainNoticeRoundTrip() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()

        #expect(rig.store.drainNotice == nil)
        rig.store.noteDrain(notice: "This phone's inbox can't be read.")
        #expect(rig.store.drainNotice == "This phone's inbox can't be read.")
        rig.store.dismissDrainNotice()
        #expect(rig.store.drainNotice == nil)
    }

    @Test("a clean pass clears a stale notice — the notice describes the LAST pass")
    func cleanPassClearsTheNotice() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        rig.store.noteDrain(notice: "1 capture couldn't be imported.")
        // The phone drains on every activation, so a condition that still holds says so
        // again within seconds; one that does not must stop being on screen.
        rig.store.noteDrain(notice: nil)
        #expect(rig.store.drainNotice == nil)
    }

    @Test("a notice is not an ingest — the two signals do not move each other")
    func noticeAndIngestAreIndependent() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        rig.store.noteDrain(notice: "something")
        #expect(rig.store.ingestGeneration == 0)
        rig.store.noteIngest()
        #expect(rig.store.drainNotice == "something")
    }

    // MARK: - How many collections there are (098 · P6)

    @Test("the collection count is the whole flattened tree, Unsorted included")
    func collectionCountCountsTheTree() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        // Before a bootstrap there is no tree, and the answer is zero rather than a crash:
        // `BrowseEmptyState` reads it in exactly that state on a failed launch.
        #expect(rig.store.collectionCount == 0)

        await rig.store.bootstrap()
        let flattened = BrowseCollectionTree.flattened(rig.store.collections).count
        #expect(rig.store.collectionCount == flattened)
        // A fresh library is Unsorted and nothing else, which is what makes
        // `BrowseEmptyState.emptyLibrary` decidable without a second read.
        #expect(rig.store.collectionCount == 1)
    }

    @Test("a nested collection is counted, so depth cannot hide a filed library")
    func collectionCountIncludesChildren() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()
        let services = try #require(rig.store.services)

        let parent = try await services.createCollection(name: "Textures")
        _ = try await services.createCollection(name: "Concrete", parent: parent.id)
        await rig.store.refreshCollections()

        // Unsorted + Textures + Concrete. A count of top-level nodes would say 2 and make
        // a library with everything nested one level down read as "nothing saved yet".
        #expect(rig.store.collectionCount == 3)
    }

    // MARK: - The two unconditional stores (098 · finding 14)

    @Test("a refresh that finds the same tree does not invalidate the views reading it")
    func refreshDoesNotFireWhenNothingChanged() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()

        let fired = Flag()
        withObservationTracking {
            _ = rig.store.collections
            _ = rig.store.collectionCovers
        } onChange: {
            fired.set()
        }

        await rig.store.refreshCollections()

        // The property, stated without saying who provides it. 098 · finding 14 predicted
        // that the unconditional store published an identical tree on every root reload;
        // `observationAlreadySuppressesASameValueStore` below is what happened when that
        // was actually asked. The `!=` guard is here regardless, because the requirement
        // should not rest on a conformance nobody would think to keep.
        #expect(!fired.isSet, "an unchanged tree still invalidated its readers")
    }

    @Test("Observation itself already suppresses a same-value store — finding 14's premise")
    func observationAlreadySuppressesASameValueStore() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()
        let tree = rig.store.collections
        #expect(!tree.isEmpty)

        // Straight at the macro, with no guard in the way: since Swift 6.3 the setter
        // `@Observable` generates compares an `Equatable` stored property and does not
        // notify when nothing changed. So the "roughly three grid evaluations per reload"
        // 098 · finding 14 costed were already not being spent, and the `!=` guards this
        // phase added are a statement of intent rather than a fix.
        //
        // Pinned here because the behaviour is silent in both directions: it arrived
        // without anything in this program noticing, and it would leave the same way — a
        // node type that stopped being `Equatable` restores the finding exactly.
        let fired = Flag()
        withObservationTracking { _ = rig.store.collections } onChange: { fired.set() }
        rig.store.setCollectionsForTesting(tree)
        #expect(!fired.isSet)

        let refired = Flag()
        withObservationTracking { _ = rig.store.collections } onChange: { refired.set() }
        rig.store.setCollectionsForTesting([])
        #expect(refired.isSet)
    }

    @Test("a refresh that finds a NEW collection does invalidate them")
    func refreshFiresWhenTheTreeChanged() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()
        let services = try #require(rig.store.services)

        let fired = Flag()
        withObservationTracking { _ = rig.store.collections } onChange: { fired.set() }

        // A collection made on the Mac since launch — the reason `refreshCollections`
        // exists at all.
        _ = try await services.createCollection(name: "Textures")
        await rig.store.refreshCollections()

        #expect(fired.isSet)
        #expect(rig.store.collections.contains { $0.collection.name == "Textures" })
    }

    @Test("a cover that appears invalidates the switcher; an unchanged map does not")
    func coversAreGuardedToo() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.bootstrap()
        let services = try #require(rig.store.services)
        #expect(rig.store.collectionCovers.isEmpty)

        let firstFired = Flag()
        withObservationTracking { _ = rig.store.collectionCovers } onChange: {
            firstFired.set()
        }
        _ = try await services.ingest(
            AssetDraft(
                kind: .image, blobHash: String(repeating: "1", count: 64),
                mimeType: "image/jpeg", width: 4, height: 4, fileSize: 1,
                downloadState: .downloaded),
            from: SourceDraft(
                platform: .web, originalURL: "https://example.com/1", capturedAt: Date()),
            into: BrowseLibrary.rootCollectionID)
        await rig.store.refreshCollections()
        #expect(firstFired.isSet)
        #expect(rig.store.collectionCovers[BrowseLibrary.rootCollectionID] != nil)

        let secondFired = Flag()
        withObservationTracking { _ = rig.store.collectionCovers } onChange: {
            secondFired.set()
        }
        await rig.store.refreshCollections()
        #expect(!secondFired.isSet, "an unchanged cover map still invalidated the sheet")
    }

    @Test("a refresh before bootstrap is a no-op, not a crash")
    func refreshWithoutALibrary() async throws {
        let rig = try StoreRig()
        defer { rig.cleanup() }
        await rig.store.refreshCollections()
        #expect(rig.store.collections.isEmpty)
        #expect(rig.store.phase == .loading)
    }

    // MARK: - Fixtures

    private static func asset() -> Asset {
        Asset(
            id: UUID(), kind: .image, blobHash: String(repeating: "a", count: 64),
            mimeType: "image/jpeg", width: 4, height: 4, fileSize: 1,
            downloadState: .downloaded, createdAt: Date(), sourceId: UUID())
    }
}

/// A counter two isolation domains can share.
private final class Counter: Sendable {
    private let box = Mutex(0)
    @discardableResult
    func bump() -> Int { box.withLock { $0 += 1; return $0 } }
    var value: Int { box.withLock { $0 } }
}
