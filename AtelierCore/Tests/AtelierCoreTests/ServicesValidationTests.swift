// AtelierCore — App Services validation tests (chunk 5, decision C8)
//
// Exercises every `Validation` helper directly: each accepts valid input and
// throws the RIGHT `AtelierError` case on each invalid input. These are the
// centralized rules the write funnel runs before any row is written.

import Foundation
import Testing
@testable import AtelierCore

@Suite("Services: validation (C8)")
struct ServicesValidationTests {

    // MARK: collectionName

    @Test("collectionName trims and returns the normalized value")
    func nameTrims() throws {
        #expect(try Validation.collectionName("  Refs  ") == "Refs")
    }

    @Test("collectionName rejects empty / whitespace-only", arguments: ["", "   ", "\n\t"])
    func nameRejectsEmpty(_ input: String) {
        #expect(throws: AtelierError.invalidName) {
            try Validation.collectionName(input)
        }
    }

    // MARK: dimensions

    @Test("dimensions accepts strictly positive")
    func dimsOK() throws {
        try Validation.dimensions(width: 1, height: 1)
    }

    @Test("dimensions rejects non-positive", arguments: [
        (0, 10), (10, 0), (-1, 10), (10, -1),
    ] as [(Int, Int)])
    func dimsReject(w: Int, h: Int) {
        #expect(throws: AtelierError.invalidDimensions) {
            try Validation.dimensions(width: w, height: h)
        }
    }

    // MARK: fileSize

    @Test("fileSize allows zero and positive")
    func fileSizeOK() throws {
        try Validation.fileSize(0)
        try Validation.fileSize(1024)
    }

    @Test("fileSize rejects negative")
    func fileSizeReject() {
        #expect(throws: AtelierError.invalidFileSize) { try Validation.fileSize(-1) }
    }

    // MARK: blobHash

    @Test("blobHash normalizes to lowercase hex")
    func blobHashNormalizes() throws {
        #expect(try Validation.blobHash("ABCDEF0123") == "abcdef0123")
    }

    @Test("blobHash rejects empty / non-hex", arguments: ["", "xyz!", "ghij", "12 34"])
    func blobHashReject(_ input: String) {
        #expect(throws: AtelierError.invalidBlobHash) {
            try Validation.blobHash(input)
        }
    }

    // MARK: canvasPlacement — the Phase-1 NaN/inf bug class

    @Test("canvasPlacement accepts finite values incl. negative x/y")
    func placementOK() throws {
        try Validation.canvasPlacement(x: -100, y: -50, w: 320, h: 240)
        try Validation.canvasPlacement(x: nil, y: nil, w: nil, h: nil) // all unset
    }

    @Test("canvasPlacement rejects non-finite coordinates")
    func placementRejectsNonFinite() {
        #expect(throws: AtelierError.invalidPlacement) {
            try Validation.canvasPlacement(x: .nan, y: 0, w: 10, h: 10)
        }
        #expect(throws: AtelierError.invalidPlacement) {
            try Validation.canvasPlacement(x: 0, y: .infinity, w: 10, h: 10)
        }
        #expect(throws: AtelierError.invalidPlacement) {
            try Validation.canvasPlacement(x: 0, y: 0, w: .nan, h: 10)
        }
    }

    @Test("canvasPlacement rejects non-positive width/height")
    func placementRejectsNonPositiveSize() {
        #expect(throws: AtelierError.invalidPlacement) {
            try Validation.canvasPlacement(x: 0, y: 0, w: 0, h: 10)
        }
        #expect(throws: AtelierError.invalidPlacement) {
            try Validation.canvasPlacement(x: 0, y: 0, w: 10, h: -5)
        }
    }

    // MARK: originalURL — per-platform provenance rule

    @Test("originalURL is required for remote platforms", arguments: [
        Platform.twitter, .pinterest, .instagram, .cosmos, .web,
    ])
    func urlRequiredRemote(_ platform: Platform) {
        #expect(throws: AtelierError.missingOriginalURL(platform: platform)) {
            try Validation.originalURL(nil, platform: platform)
        }
        #expect(throws: AtelierError.missingOriginalURL(platform: platform)) {
            try Validation.originalURL("   ", platform: platform)
        }
        // A real URL passes.
        #expect(throws: Never.self) {
            try Validation.originalURL("https://example.com/x", platform: platform)
        }
    }

    @Test("originalURL is optional for local capture paths", arguments: [
        Platform.localPaste, .localDrag,
    ])
    func urlOptionalLocal(_ platform: Platform) throws {
        try Validation.originalURL(nil, platform: platform)
        try Validation.originalURL("file:///x.png", platform: platform)
    }
}
