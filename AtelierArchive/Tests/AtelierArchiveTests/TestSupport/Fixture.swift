// AtelierArchiveTests — committed fixtures, and the one way to load them (12A).
//
// **Why this exists.** Every test in this target builds its input in code: a
// manifest assembled from `ArchiveManifest(...)`, an inbox record from a literal.
// That is fine for a contract this package OWNS, and useless for one it does not.
// The importers 12A schedules (Eagle, Raindrop, Pinterest — 099 · P18–P20) parse
// files written by other programs, and a parser tested against JSON the test
// itself wrote is a parser tested against the author's belief about the format.
// The fixtures that matter are BYTES SOMEONE ELSE PRODUCED, committed unchanged.
//
// So: `Fixtures/` is copied into the test bundle, and this file is the only way
// its contents are read. One loader rather than a `Bundle.module.url(...)` at each
// call site, because a missing fixture should say which name failed, not return a
// `nil` that unwraps into an unrelated crash three lines later.
//
// **What does NOT change.** The in-code fixtures already here stay as they are.
// This is infrastructure for the parsers that have no library to build from, not
// a migration of tests that are correct.

import Foundation

/// A fixture that is not in the bundle, named so the failure says which one.
struct MissingFixture: Error, CustomStringConvertible {
    let name: String
    var description: String {
        """
        No fixture named '\(name)' in the test bundle. It must live in \
        AtelierArchive/Tests/AtelierArchiveTests/Fixtures/ — the whole directory is \
        copied by `resources: [.copy("Fixtures")]`, so a new file needs no \
        Package.swift edit, only `swift test` re-running.
        """
    }
}

/// The URL of a committed fixture. `name` carries its extension
/// (`"smoke-manifest.json"`), because that is what the file is called and a
/// caller should not have to take it apart.
func fixtureURL(named name: String) throws -> URL {
    let dotted = name.split(separator: ".", omittingEmptySubsequences: false)
    let ext = dotted.count > 1 ? String(dotted.last!) : ""
    let base = dotted.count > 1 ? dotted.dropLast().joined(separator: ".") : name
    guard let url = Bundle.module.url(
        forResource: base, withExtension: ext, subdirectory: "Fixtures")
    else { throw MissingFixture(name: name) }
    return url
}

/// The bytes of a committed fixture, verbatim — no decoding, no normalization.
/// A parser test wants the bytes; a golden test wants the bytes; anything that
/// wants a value decodes these itself with the codec under test.
func fixture(named name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(named: name))
}
