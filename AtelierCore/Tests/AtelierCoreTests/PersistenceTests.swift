// AtelierCore — persistence suite (chunk 4)
//
// Exercises the GRDB record conformances (A1), the C5 text encodings, the
// `.convertToSnakeCase` column mapping for the tricky acronym properties, the
// JSON storage of `Source.rawMetadata`, and the P14 single joined read — all
// over the real temp-file `DatabasePool` store (T9, via `makeTempDatabase`).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

// MARK: - Fixtures

/// Dates constructed at exact integer-millisecond offsets so they survive
/// GRDB's default `YYYY-MM-DD HH:MM:SS.SSS` text round-trip with equality. The
/// fractional parts (.125/.25/.5/.75) are exact in both binary and milliseconds.
private enum Fixtures {
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
    static let createdAt = Date(timeIntervalSince1970: 1_700_000_111.250)
    static let collectionCreatedAt = Date(timeIntervalSince1970: 1_700_000_222.500)
    static let collectionUpdatedAt = Date(timeIntervalSince1970: 1_700_000_333.750)
    static let addedAt1 = Date(timeIntervalSince1970: 1_700_000_444.125)
    static let addedAt2 = Date(timeIntervalSince1970: 1_700_000_555.375)

    /// A multi-level nested metadata document (object → array → object → …) to
    /// prove `JSONValue` survives a full JSON round-trip through the TEXT column.
    static let richMetadata: JSONValue = .object([
        "board": .string("interior-inspo"),
        "tweet_id": .number(1_234_567_890),
        "pinned": .bool(true),
        "missing": .null,
        "tags": .array([.string("wood"), .string("brass"), .number(42)]),
        "nested": .object([
            "cluster": .string("warm-minimal"),
            "scores": .array([.number(0.5), .number(0.25), .bool(false)]),
        ]),
    ])

    static func fullSource(id: UUID = UUID()) -> Source {
        Source(
            id: id,
            platform: .pinterest,
            originalURL: "https://pinterest.com/pin/42",
            authorHandle: "@designer",
            authorName: "A. Designer",
            title: "Brass + wood study",
            capturedAt: capturedAt,
            rawMetadata: richMetadata
        )
    }

    static func fullAsset(id: UUID = UUID(), sourceId: UUID) -> Asset {
        Asset(
            id: id,
            kind: .video,
            blobHash: "abc123def456",
            mimeType: "video/mp4",
            width: 1920,
            height: 1080,
            duration: 12.5,
            fileSize: 8_388_608,
            downloadState: .downloaded,
            createdAt: createdAt,
            sourceId: sourceId
        )
    }

    static func fullCollection(id: UUID = UUID(), coverAssetID: UUID?) -> Collection {
        Collection(
            id: id,
            name: "References",
            description: "A working set",
            coverAssetID: coverAssetID,
            createdAt: collectionCreatedAt,
            updatedAt: collectionUpdatedAt
        )
    }

    static func fullItem(
        id: UUID = UUID(),
        collectionID: UUID,
        assetID: UUID,
        addedAt: Date,
        manualOrder: Int
    ) -> CollectionItem {
        CollectionItem(
            id: id,
            collectionID: collectionID,
            assetID: assetID,
            addedAt: addedAt,
            manualOrder: manualOrder,
            canvasX: 120.5,
            canvasY: 480.25,
            canvasW: 320.0,
            canvasH: 240.0,
            canvasZ: 7
        )
    }
}

/// Insert a source + asset (+ optional cover'd collection) so dependent rows
/// satisfy their FKs. Returns the inserted source & asset.
@discardableResult
private func seedSourceAndAsset(
    _ store: LibraryDatabase
) throws -> (source: Source, asset: Asset) {
    let source = Fixtures.fullSource()
    let asset = Fixtures.fullAsset(sourceId: source.id)
    try store.write { db in
        try source.insert(db)
        try asset.insert(db)
    }
    return (source, asset)
}

// MARK: - Round-trip each record

@Suite("Persistence: record round-trips")
struct RecordRoundTripTests {

    @Test("Source round-trips with all fields + nested rawMetadata")
    func sourceRoundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()

        try temp.database.write { try source.insert($0) }
        let fetched = try temp.database.read { db in
            try Source.filter(Column("id") == source.id.uuidString.lowercased())
                .fetchOne(db)
        }
        #expect(fetched == source)
    }

    @Test("Asset round-trips with all optionals populated")
    func assetRoundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()
        let asset = Fixtures.fullAsset(sourceId: source.id)

        try temp.database.write { db in
            try source.insert(db)
            try asset.insert(db)
        }
        let fetched = try temp.database.read { db in
            try Asset.filter(Column("id") == asset.id.uuidString.lowercased())
                .fetchOne(db)
        }
        #expect(fetched == asset)
    }

    @Test("Collection round-trips with cover + description")
    func collectionRoundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)
        let collection = Fixtures.fullCollection(coverAssetID: asset.id)

        try temp.database.write { try collection.insert($0) }
        let fetched = try temp.database.read { db in
            try Collection.filter(Column("id") == collection.id.uuidString.lowercased())
                .fetchOne(db)
        }
        #expect(fetched == collection)
    }

    @Test("CollectionItem round-trips with all canvas_* + manual_order")
    func collectionItemRoundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)
        let collection = Fixtures.fullCollection(coverAssetID: nil)
        let item = Fixtures.fullItem(
            collectionID: collection.id, assetID: asset.id,
            addedAt: Fixtures.addedAt1, manualOrder: 3)

        try temp.database.write { db in
            try collection.insert(db)
            try item.insert(db)
        }
        let fetched = try temp.database.read { db in
            try CollectionItem.filter(Column("id") == item.id.uuidString.lowercased())
                .fetchOne(db)
        }
        #expect(fetched == item)
    }

    @Test("Tag round-trips")
    func tagRoundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let tag = Tag(id: UUID(), name: "warm", source: .agent)

        try temp.database.write { try tag.insert($0) }
        let fetched = try temp.database.read { db in
            try Tag.filter(Column("id") == tag.id.uuidString.lowercased()).fetchOne(db)
        }
        #expect(fetched == tag)
    }

    @Test("AssetTag (composite PK, no id) round-trips")
    func assetTagRoundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)
        let tag = Tag(id: UUID(), name: "brass", source: .user)
        let link = AssetTag(assetID: asset.id, tagID: tag.id)

        try temp.database.write { db in
            try tag.insert(db)
            try link.insert(db)
        }
        let fetched = try temp.database.read { db in
            try AssetTag
                .filter(Column("asset_id") == asset.id.uuidString.lowercased())
                .filter(Column("tag_id") == tag.id.uuidString.lowercased())
                .fetchOne(db)
        }
        #expect(fetched == link)
    }
}

// MARK: - C5 text encodings

@Suite("Persistence: C5 text encodings")
struct TextEncodingTests {

    @Test("UUID id is stored as a 36-char lowercased TEXT string, not a blob")
    func uuidStoredAsText() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)

        let raw = try temp.database.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM asset WHERE id = ?",
                arguments: [asset.id.uuidString.lowercased()])
        }
        #expect(raw == asset.id.uuidString.lowercased())
        #expect(raw?.count == 36)
        #expect(raw == raw?.lowercased())
    }

    @Test("Date is stored as sortable millisecond text (YYYY-MM-DD HH:MM:SS.SSS)")
    func dateStoredAsSortableText() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (source, _) = try seedSourceAndAsset(temp.database)

        let raw = try temp.database.read { db in
            try String.fetchOne(
                db, sql: "SELECT captured_at FROM source WHERE id = ?",
                arguments: [source.id.uuidString.lowercased()])
        }
        // Format: 19 chars of "YYYY-MM-DD HH:MM:SS" + ".SSS" milliseconds.
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#
        #expect(raw?.range(of: pattern, options: .regularExpression) != nil,
                "captured_at was \(raw ?? "nil")")
    }

    @Test("enum rawValues are stored as String (platform = pinterest)")
    func enumStoredAsString() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (source, _) = try seedSourceAndAsset(temp.database)

        let raw = try temp.database.read { db in
            try String.fetchOne(
                db, sql: "SELECT platform FROM source WHERE id = ?",
                arguments: [source.id.uuidString.lowercased()])
        }
        #expect(raw == Platform.pinterest.rawValue)
    }
}

// MARK: - .convertToSnakeCase acronym column mapping

@Suite("Persistence: snake_case column mapping (acronyms)")
struct ColumnMappingTests {

    /// Read a single TEXT column by the asset/source/collection/item id.
    private func text(
        _ store: LibraryDatabase, _ sql: String, _ id: UUID
    ) throws -> String? {
        try store.read { db in
            try String.fetchOne(db, sql: sql, arguments: [id.uuidString.lowercased()])
        }
    }

    @Test("originalURL maps to original_url and round-trips")
    func originalURL() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()
        try temp.database.write { try source.insert($0) }

        let value = try text(
            temp.database, "SELECT original_url FROM source WHERE id = ?", source.id)
        #expect(value == source.originalURL)
    }

    @Test("sourceId maps to source_id")
    func sourceId() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (source, asset) = try seedSourceAndAsset(temp.database)

        let value = try text(
            temp.database, "SELECT source_id FROM asset WHERE id = ?", asset.id)
        #expect(value == source.id.uuidString.lowercased())
    }

    @Test("coverAssetID maps to cover_asset_id")
    func coverAssetID() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)
        let collection = Fixtures.fullCollection(coverAssetID: asset.id)
        try temp.database.write { try collection.insert($0) }

        let value = try text(
            temp.database, "SELECT cover_asset_id FROM collection WHERE id = ?",
            collection.id)
        #expect(value == asset.id.uuidString.lowercased())
    }

    @Test("collectionID/assetID map to collection_id/asset_id")
    func itemForeignKeys() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)
        let collection = Fixtures.fullCollection(coverAssetID: nil)
        let item = Fixtures.fullItem(
            collectionID: collection.id, assetID: asset.id,
            addedAt: Fixtures.addedAt1, manualOrder: 1)
        try temp.database.write { db in
            try collection.insert(db)
            try item.insert(db)
        }

        let row = try temp.database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT collection_id, asset_id FROM collection_item WHERE id = ?",
                arguments: [item.id.uuidString.lowercased()])
        }
        #expect(row?["collection_id"] == collection.id.uuidString.lowercased())
        #expect(row?["asset_id"] == asset.id.uuidString.lowercased())
    }

    @Test("AssetTag.tagID maps to tag_id")
    func tagID() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let (_, asset) = try seedSourceAndAsset(temp.database)
        let tag = Tag(id: UUID(), name: "wood", source: .user)
        let link = AssetTag(assetID: asset.id, tagID: tag.id)
        try temp.database.write { db in
            try tag.insert(db)
            try link.insert(db)
        }

        let value = try temp.database.read { db in
            try String.fetchOne(
                db, sql: "SELECT tag_id FROM asset_tag WHERE asset_id = ?",
                arguments: [asset.id.uuidString.lowercased()])
        }
        #expect(value == tag.id.uuidString.lowercased())
    }
}

// MARK: - rawMetadata JSON storage

@Suite("Persistence: rawMetadata JSON")
struct RawMetadataTests {

    @Test("nested rawMetadata round-trips identically")
    func roundTrip() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()
        try temp.database.write { try source.insert($0) }

        let fetched = try temp.database.read { db in
            try Source.filter(Column("id") == source.id.uuidString.lowercased())
                .fetchOne(db)
        }
        #expect(fetched?.rawMetadata == Fixtures.richMetadata)
    }

    @Test("raw_metadata column holds valid JSON text")
    func validJSONText() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()
        try temp.database.write { try source.insert($0) }

        let raw = try temp.database.read { db in
            try String.fetchOne(
                db, sql: "SELECT raw_metadata FROM source WHERE id = ?",
                arguments: [source.id.uuidString.lowercased()])
        }
        let data = try #require(raw?.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data)
        // Top level is a JSON object.
        #expect(parsed is [String: Any])
    }
}

// MARK: - P14 joined read

@Suite("Persistence: P14 joined read")
struct JoinedReadTests {

    @Test("collectionItemDetails returns each item with nested asset+source, ordered")
    func joinedRead() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()
        let asset = Fixtures.fullAsset(sourceId: source.id)
        let collection = Fixtures.fullCollection(coverAssetID: nil)
        // Insert items out of order (manual_order 2 then 1) to prove ordering.
        let item2 = Fixtures.fullItem(
            collectionID: collection.id, assetID: asset.id,
            addedAt: Fixtures.addedAt2, manualOrder: 2)
        let item1 = Fixtures.fullItem(
            collectionID: collection.id, assetID: asset.id,
            addedAt: Fixtures.addedAt1, manualOrder: 1)

        try temp.database.write { db in
            try source.insert(db)
            try asset.insert(db)
            try collection.insert(db)
            try item2.insert(db)
            try item1.insert(db)
        }

        let details = try temp.database.collectionItemDetails(in: collection.id)
        try #require(details.count == 2)
        // Ordered by manual_order ascending → item1 (1) before item2 (2).
        #expect(details.map(\.item.manualOrder) == [1, 2])
        #expect(details[0].item == item1)
        #expect(details[1].item == item2)
        // Each row carries the correct fully-decoded asset + source.
        for detail in details {
            #expect(detail.asset == asset)
            #expect(detail.source == source)
        }
    }

    @Test("collectionItemDetails scopes to the requested collection only")
    func scopedToCollection() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        let source = Fixtures.fullSource()
        let asset = Fixtures.fullAsset(sourceId: source.id)
        let collectionA = Fixtures.fullCollection(coverAssetID: nil)
        let collectionB = Fixtures.fullCollection(coverAssetID: nil)
        let itemA = Fixtures.fullItem(
            collectionID: collectionA.id, assetID: asset.id,
            addedAt: Fixtures.addedAt1, manualOrder: 1)
        let itemB = Fixtures.fullItem(
            collectionID: collectionB.id, assetID: asset.id,
            addedAt: Fixtures.addedAt2, manualOrder: 1)

        try temp.database.write { db in
            try source.insert(db)
            try asset.insert(db)
            try collectionA.insert(db)
            try collectionB.insert(db)
            try itemA.insert(db)
            try itemB.insert(db)
        }

        let detailsA = try temp.database.collectionItemDetails(in: collectionA.id)
        #expect(detailsA.count == 1)
        #expect(detailsA.first?.item == itemA)
    }
}

// MARK: - FK enforcement through the store

@Suite("Persistence: FK enforcement")
struct ForeignKeyTests {

    @Test("inserting an asset with a missing source throws (FK enforced)")
    func orphanAssetRejected() throws {
        let temp = try makeTempDatabase()
        defer { temp.cleanup() }
        // No source inserted: source_id dangles.
        let orphan = Fixtures.fullAsset(sourceId: UUID())

        #expect(throws: (any Error).self) {
            try temp.database.write { try orphan.insert($0) }
        }
    }
}
