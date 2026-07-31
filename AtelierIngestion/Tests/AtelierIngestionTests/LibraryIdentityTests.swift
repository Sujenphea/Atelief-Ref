// AtelierIngestion tests — the stable name a library answers to (008 · H5).
//
// This id becomes a directory name inside a folder the user chose, so two
// things matter more than the rest: it must not change once minted (a changed
// id silently starts a second, empty backup beside the real one), and it must
// never be anything but hex (it is interpolated into a path).

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("LibraryIdentity (008 H5)")
struct LibraryIdentityTests {

    /// A fresh empty directory, cleaned up by the caller.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierIdentityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Minting

    @Test("a fresh library gets a well-formed id, persisted at the root")
    func mintsAndPersists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = try LibraryIdentity.resolve(root: root)
        #expect(LibraryIdentity.isWellFormed(id))

        let file = root.appendingPathComponent(LibraryIdentity.fileName)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk == id)
    }

    @Test("the id is STABLE — resolving again returns the same one")
    func isStableAcrossCalls() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The property the whole destination layout rests on: a changed id points
        // the next backup at a fresh empty folder beside the real one.
        let first = try LibraryIdentity.resolve(root: root)
        let second = try LibraryIdentity.resolve(root: root)
        #expect(first == second)
    }

    @Test("two libraries get different ids")
    func distinctPerLibrary() throws {
        let a = try makeRoot()
        let b = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(try LibraryIdentity.resolve(root: a) != LibraryIdentity.resolve(root: b))
    }

    @Test("a root that doesn't exist yet is created")
    func createsMissingRoot() throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("not-yet", isDirectory: true)

        let id = try LibraryIdentity.resolve(root: root)
        #expect(LibraryIdentity.isWellFormed(id))
    }

    @Test("surrounding whitespace in the file is tolerated")
    func trimsStoredValue() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Someone `echo`-ing a value in gets a trailing newline; that is not a
        // reason to declare their library unidentifiable.
        let file = root.appendingPathComponent(LibraryIdentity.fileName)
        try "  0123456789abcdef\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(try LibraryIdentity.resolve(root: root) == "0123456789abcdef")
    }

    // MARK: - Refusing a bad id

    @Test("a malformed id file THROWS rather than minting a replacement")
    func malformedThrows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(LibraryIdentity.fileName)
        try "not-a-hex-id".write(to: file, atomically: true, encoding: .utf8)

        // Re-minting would strand every blob already copied under the old id and
        // start the whole backup again in a new folder — with no user-visible
        // signal but the folder doubling in size.
        #expect(throws: LibraryIdentity.IdentityError.malformed("not-a-hex-id")) {
            try LibraryIdentity.resolve(root: root)
        }
        // And the bad file is left exactly as found, not silently repaired.
        #expect(try String(contentsOf: file, encoding: .utf8) == "not-a-hex-id")
    }

    @Test("path separators and traversal are not well-formed")
    func rejectsPathTricks() {
        // The id is interpolated into `<target>/<id>/`; these must never pass.
        #expect(!LibraryIdentity.isWellFormed("../../../etc/pw"))
        #expect(!LibraryIdentity.isWellFormed("0123456789ab/def"))
        #expect(!LibraryIdentity.isWellFormed(".."))
        #expect(!LibraryIdentity.isWellFormed("0123456789abcde."))
    }

    @Test("uppercase hex is not well-formed — case-insensitive volumes collide")
    func rejectsUppercase() {
        #expect(LibraryIdentity.isWellFormed("0123456789abcdef"))
        // On the default case-insensitive APFS volume these two ids would land
        // in ONE directory, so only one spelling may ever be minted.
        #expect(!LibraryIdentity.isWellFormed("0123456789ABCDEF"))
    }

    @Test("only literal ASCII hex counts, not Unicode digit lookalikes")
    func rejectsUnicodeDigits() {
        // `Character.isHexDigit` is true for fullwidth forms; a directory named
        // with them is legal on disk and untypeable by a human.
        #expect(!LibraryIdentity.isWellFormed("０123456789abcdef"))
    }

    @Test("length is exact — no short or long ids")
    func rejectsWrongLength() {
        #expect(!LibraryIdentity.isWellFormed(""))
        #expect(!LibraryIdentity.isWellFormed("0123456789abcde"))
        #expect(!LibraryIdentity.isWellFormed("0123456789abcdef0"))
    }

    @Test("everything minted is well-formed")
    func mintedValuesAreWellFormed() {
        for _ in 0 ..< 200 {
            #expect(LibraryIdentity.isWellFormed(LibraryIdentity.makeIdentifier()))
        }
    }
}
