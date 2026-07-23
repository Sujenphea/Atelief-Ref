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

    // MARK: uniqueCollectionName — Finder-style sibling disambiguation (043 · 2c)

    @Test("no collision returns the name unchanged")
    func uniqueNoCollision() {
        #expect(Validation.uniqueCollectionName("Refs", among: ["Notes", "Art"]) == "Refs")
        #expect(Validation.uniqueCollectionName("Refs", among: []) == "Refs")
    }

    @Test("a collision appends the smallest free ` N` (N ≥ 2)")
    func uniqueFirstCollision() {
        #expect(Validation.uniqueCollectionName("Refs", among: ["Refs"]) == "Refs 2")
    }

    @Test("numbering walks past taken ` N` slots")
    func uniqueWalksSequence() {
        #expect(
            Validation.uniqueCollectionName("Refs", among: ["Refs", "Refs 2", "Refs 3"])
                == "Refs 4")
    }

    @Test("a gap in the numbered family is filled")
    func uniqueFillsGap() {
        #expect(
            Validation.uniqueCollectionName("Refs", among: ["Refs", "Refs 3"]) == "Refs 2")
    }

    @Test("an already-numbered desired name collapses onto its base, not `Refs 2 2`")
    func uniqueCollapsesNumberedBase() {
        #expect(
            Validation.uniqueCollectionName("Refs 2", among: ["Refs", "Refs 2"]) == "Refs 3")
    }

    @Test("matching is case-insensitive; the desired name's casing is kept")
    func uniqueCaseInsensitive() {
        #expect(Validation.uniqueCollectionName("REFS", among: ["refs"]) == "REFS 2")
        #expect(Validation.uniqueCollectionName("refs", among: ["Refs", "REFS 2"]) == "refs 3")
    }

    @Test("` 0` / ` 1` are below the numbering floor and treated as the whole base")
    func uniqueLowIndexKeptAsBase() {
        // "Refs 1" doesn't strip to "Refs" — it is its own base, so a collision
        // becomes "Refs 1 2".
        #expect(Validation.uniqueCollectionName("Refs 1", among: ["Refs 1"]) == "Refs 1 2")
    }

    // MARK: tagName — leading '#' is a UI affordance, not part of the name

    @Test("tagName strips a leading '#' and trims", arguments: [
        ("#sf", "sf"), ("# sf", "sf"), ("  #sf  ", "sf"), ("sf", "sf"),
        ("c#", "c#"),               // a non-leading '#' is preserved
    ] as [(String, String)])
    func tagNameStripsHash(_ input: String, _ expected: String) throws {
        #expect(try Validation.tagName(input) == expected)
    }

    @Test("tagName rejects empty / '#'-only", arguments: ["", "  ", "#", "#  "])
    func tagNameRejectsEmpty(_ input: String) {
        #expect(throws: AtelierError.invalidName) { try Validation.tagName(input) }
    }

    @Test("normalizedTagName is non-throwing and may return empty")
    func normalizedTagNameEmpty() {
        #expect(Validation.normalizedTagName("#") == "")
        #expect(Validation.normalizedTagName("#sf") == "sf")
        #expect(Validation.normalizedTagName("  plain ") == "plain")
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
