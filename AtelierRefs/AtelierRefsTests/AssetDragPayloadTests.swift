//
//  AssetDragPayloadTests.swift
//  AtelierRefsTests
//
//  Guards the intra-app drag payload (009 · N3): the dragged asset ids plus their
//  source collection. Its `Transferable` representation rides on the custom
//  `.assetIDs` UTI (`CodableRepresentation`), so the meaningful invariant is that
//  its `Codable` form round-trips unchanged — exactly the wire format a drag
//  serializes and a drop decodes.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("AssetDragPayload")
struct AssetDragPayloadTests {

    @Test("Codable round-trips (the .assetIDs transfer representation)")
    func codableRoundTrip() throws {
        let payload = AssetDragPayload(
            assetIDs: [UUID(), UUID()], sourceCollectionID: UUID())
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AssetDragPayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.assetIDs == payload.assetIDs)
        #expect(decoded.sourceCollectionID == payload.sourceCollectionID)
    }

    @Test("payloads differing in ids or source are not equal")
    func inequality() {
        let source = UUID()
        let asset = UUID()
        // Different assets, same source.
        #expect(AssetDragPayload(assetIDs: [asset], sourceCollectionID: source)
                != AssetDragPayload(assetIDs: [UUID()], sourceCollectionID: source))
        // Same asset, different source.
        #expect(AssetDragPayload(assetIDs: [asset], sourceCollectionID: source)
                != AssetDragPayload(assetIDs: [asset], sourceCollectionID: UUID()))
    }
}

@Suite("Import status composition (7A)")
struct ImportStatusTests {

    @Test("all imported → plain count, no clauses")
    func cleanBatch() {
        #expect(IngestionModel.importStatus(imported: 3, failures: 0, undecoded: 0)
                == "Imported 3.")
    }

    @Test("some failed → a failed clause")
    func withFailures() {
        #expect(IngestionModel.importStatus(imported: 2, failures: 1, undecoded: 0)
                == "Imported 2, 1 failed.")
    }

    @Test("some unreadable → an unreadable clause (partial drop)")
    func withUndecoded() {
        #expect(IngestionModel.importStatus(imported: 2, failures: 0, undecoded: 1)
                == "Imported 2, 1 couldn't be read.")
    }

    @Test("both failed and unreadable → both clauses, in order")
    func withBoth() {
        #expect(IngestionModel.importStatus(imported: 1, failures: 2, undecoded: 3)
                == "Imported 1, 2 failed, 3 couldn't be read.")
    }
}
