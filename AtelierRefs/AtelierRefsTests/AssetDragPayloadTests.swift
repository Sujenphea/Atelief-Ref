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

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
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

    // MARK: - NSPasteboard ↔ SwiftUI byte-compatibility (036 §4 A3)
    //
    // The interop contract: the AppKit drag out writes bytes the still-SwiftUI
    // sidebar rows / Spaces (each a `.dropDestination(for: AssetDragPayload.self)`)
    // accept. SwiftUI's `CodableRepresentation(contentType:)` serializes with a plain
    // `JSONEncoder` under the content type's identifier, so proving byte-compat is
    // proving (a) `pasteboardData()` equals `JSONEncoder().encode`, (b) it decodes
    // back through the same `Codable` form, and (c) the pasteboard type is exactly
    // the `.assetIDs` UTI the SwiftUI representation registers under. A drift in any
    // of the three silently breaks drag-to-rail — this suite catches it.

    @Test("the pasteboard type IS the .assetIDs UTI the SwiftUI representation uses")
    func pasteboardTypeMatchesUTI() {
        #expect(AssetDragPayload.pasteboardType.rawValue == "com.ref-atelier.asset-ids")
        #expect(AssetDragPayload.pasteboardType.rawValue == UTType.assetIDs.identifier)
    }

    @Test("pasteboardData() bytes are exactly the SwiftUI CodableRepresentation wire form")
    func pasteboardBytesMatchCodableRepresentation() throws {
        let payload = AssetDragPayload(
            assetIDs: [UUID(), UUID(), UUID()], sourceCollectionID: UUID())
        // The exact bytes SwiftUI's `CodableRepresentation` produces (plain JSON).
        let swiftUIBytes = try JSONEncoder().encode(payload)
        #expect(try payload.pasteboardData() == swiftUIBytes)
        // And they decode back through the same `Codable` form a SwiftUI drop uses.
        #expect(try JSONDecoder().decode(AssetDragPayload.self, from: payload.pasteboardData())
                == payload)
    }

    @Test("the NSPasteboardItem carries decodable bytes under the assetIDs type")
    func pasteboardItemRoundTrip() throws {
        let payload = AssetDragPayload(
            assetIDs: [UUID()], sourceCollectionID: UUID())
        let item = try #require(payload.makePasteboardItem())
        let data = try #require(item.data(forType: AssetDragPayload.pasteboardType))
        // Simulate the drop side: read the bytes off the pasteboard item, decode.
        #expect(AssetDragPayload.decode(from: data) == payload)
        // And the bytes are the same wire form the SwiftUI drop targets expect.
        #expect(data == (try payload.pasteboardData()))
    }

    @Test("decode rejects garbage bytes without crashing")
    func decodeRejectsGarbage() {
        #expect(AssetDragPayload.decode(from: Data([0x00, 0x01, 0x02])) == nil)
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
