import Foundation
import Testing
@testable import AtelierCore

// Codable round-trips for every domain struct + default-initializer behaviour.
// These types are the on-disk contract (003 §data-model); a round-trip break is
// a data-loss break. Fixed UUIDs/Dates keep the assertions deterministic.
@Suite("Domain models")
struct DomainModelTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    private let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let assetID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let collectionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Codable round-trips

    @Test("Asset round-trips")
    func assetRoundTrip() throws {
        let asset = Asset(
            id: assetID,
            kind: .image,
            blobHash: "abc123",
            mimeType: "image/jpeg",
            width: 800,
            height: 600,
            duration: nil,
            fileSize: 12_345,
            downloadState: .downloaded,
            createdAt: date,
            sourceId: sourceID
        )
        #expect(try roundTrip(asset) == asset)
    }

    @Test("Asset with a video duration round-trips")
    func assetVideoRoundTrip() throws {
        let asset = Asset(
            id: assetID,
            kind: .video,
            blobHash: "def456",
            mimeType: "video/mp4",
            width: 1920,
            height: 1080,
            duration: 12.5,
            fileSize: 9_000_000,
            downloadState: .pending,
            createdAt: date,
            sourceId: sourceID
        )
        #expect(try roundTrip(asset) == asset)
    }

    @Test("Source with populated nested rawMetadata round-trips")
    func sourceRoundTrip() throws {
        let source = Source(
            id: sourceID,
            platform: .twitter,
            originalURL: "https://x.com/designer/status/1",
            authorHandle: "@designer",
            authorName: "A Designer",
            title: "a great post",
            capturedAt: date,
            rawMetadata: .object([
                "tweetId": .string("1"),
                "metrics": .object(["likes": .number(10), "rts": .number(2)]),
                "media": .array([.string("a.jpg"), .string("b.jpg")]),
            ])
        )
        #expect(try roundTrip(source) == source)
    }

    @Test("Source with default rawMetadata round-trips")
    func sourceDefaultRoundTrip() throws {
        let source = Source(id: sourceID, platform: .localPaste, capturedAt: date)
        #expect(try roundTrip(source) == source)
    }

    @Test("Collection round-trips")
    func collectionRoundTrip() throws {
        let collection = Collection(
            id: collectionID,
            name: "Type",
            description: "typography references",
            coverAssetID: assetID,
            createdAt: date,
            updatedAt: date
        )
        #expect(try roundTrip(collection) == collection)
    }

    @Test("CollectionItem with full canvas placement round-trips")
    func collectionItemRoundTrip() throws {
        let item = CollectionItem(
            id: UUID(),
            collectionID: collectionID,
            assetID: assetID,
            addedAt: date,
            manualOrder: 3,
            canvasX: 1_200,
            canvasY: 480,
            canvasW: 200,
            canvasH: 150,
            canvasZ: 5
        )
        #expect(try roundTrip(item) == item)
    }

    @Test("Tag round-trips", arguments: [TagSource.user, TagSource.agent])
    func tagRoundTrip(source: TagSource) throws {
        let tag = Tag(id: UUID(), name: "brutalist", source: source)
        #expect(try roundTrip(tag) == tag)
    }

    @Test("AssetTag join row round-trips")
    func assetTagRoundTrip() throws {
        let join = AssetTag(assetID: assetID, tagID: UUID())
        #expect(try roundTrip(join) == join)
    }

    // MARK: - Default initializers

    @Test("Asset.duration defaults to nil")
    func assetDefaults() {
        let asset = Asset(
            id: assetID, kind: .image, blobHash: "h", mimeType: "image/png",
            width: 1, height: 1, fileSize: 1, downloadState: .pending,
            createdAt: date, sourceId: sourceID
        )
        #expect(asset.duration == nil)
    }

    @Test("Source optionals default nil and rawMetadata defaults to empty object")
    func sourceDefaults() {
        let source = Source(id: sourceID, platform: .web, capturedAt: date)
        #expect(source.originalURL == nil)
        #expect(source.authorHandle == nil)
        #expect(source.authorName == nil)
        #expect(source.title == nil)
        #expect(source.rawMetadata == .object([:]))
    }

    @Test("Collection optionals default nil")
    func collectionDefaults() {
        let collection = Collection(id: collectionID, name: "n", createdAt: date, updatedAt: date)
        #expect(collection.description == nil)
        #expect(collection.coverAssetID == nil)
    }

    @Test("CollectionItem placement fields default nil")
    func collectionItemDefaults() {
        let item = CollectionItem(
            id: UUID(), collectionID: collectionID, assetID: assetID, addedAt: date
        )
        #expect(item.manualOrder == nil)
        #expect(item.canvasX == nil)
        #expect(item.canvasY == nil)
        #expect(item.canvasW == nil)
        #expect(item.canvasH == nil)
        #expect(item.canvasZ == nil)
    }

    // MARK: - Identity / Hashable sanity

    @Test("Identifiable id is the declared id")
    func identifiable() {
        let asset = Asset(
            id: assetID, kind: .image, blobHash: "h", mimeType: "image/png",
            width: 1, height: 1, fileSize: 1, downloadState: .pending,
            createdAt: date, sourceId: sourceID
        )
        #expect(asset.id == assetID)
    }

    @Test("equal values hash equally")
    func hashable() {
        let a = Tag(id: assetID, name: "x", source: .user)
        let b = Tag(id: assetID, name: "x", source: .user)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }
}
