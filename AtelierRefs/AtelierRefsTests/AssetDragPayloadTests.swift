//
//  AssetDragPayloadTests.swift
//  AtelierRefsTests
//
//  Guards the intra-app grid reorder drag payload. Its `Transferable`
//  representation rides on `.json` (`CodableRepresentation`), so the meaningful
//  invariant is that its `Codable` form round-trips through JSON unchanged — that
//  is exactly the wire format a drag serializes and a drop decodes.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("AssetDragPayload")
struct AssetDragPayloadTests {

    @Test("Codable round-trips through JSON (the .json transfer representation)")
    func codableRoundTrip() throws {
        let payload = AssetDragPayload(assetID: UUID())
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AssetDragPayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.assetID == payload.assetID)
    }

    @Test("payloads with distinct asset ids are not equal")
    func inequality() {
        #expect(AssetDragPayload(assetID: UUID()) != AssetDragPayload(assetID: UUID()))
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
