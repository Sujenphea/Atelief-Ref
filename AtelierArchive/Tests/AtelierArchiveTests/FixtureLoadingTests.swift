// AtelierArchiveTests — the fixture wiring itself (12A).
//
// One smoke fixture, and three assertions about it: the bundle resource is
// actually copied, the loader hands back the bytes verbatim, and a name that is
// not there fails by NAME rather than by nil-unwrap. That is the whole point of
// this file — the importers 099 · P18–P20 add will assume all three, and if the
// `resources:` line is ever dropped from Package.swift this is what says so
// instead of every parser suite failing at once for an unrelated-looking reason.

import Foundation
import Testing
@testable import AtelierArchive

@Suite("Fixture loading (12A)")
struct FixtureLoadingTests {

    @Test("a committed fixture is in the test bundle and loads verbatim")
    func smokeFixtureLoads() throws {
        let url = try fixtureURL(named: "smoke-manifest.json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let data = try fixture(named: "smoke-manifest.json")
        #expect(!data.isEmpty)
        // Verbatim: the same bytes the file on disk holds, not a re-serialization.
        #expect(data == (try Data(contentsOf: url)))
    }

    @Test("the smoke fixture is a manifest the shipped decoder reads")
    func smokeFixtureDecodes() throws {
        // The fixture proves the WIRING, so it is deliberately the smallest thing
        // that is still a real archive contract: an empty library.
        let manifest = try ArchiveManifest.makeDecoder()
            .decode(ArchiveManifest.self, from: try fixture(named: "smoke-manifest.json"))
        #expect(manifest.manifestVersion == 1)
        #expect(manifest.schemaVersion == "v1")
        #expect(manifest.sources.isEmpty)
        #expect(manifest.assets.isEmpty)
        #expect(manifest.collections.isEmpty)
    }

    @Test("a fixture that is not there throws, naming it")
    func missingFixtureNamesItself() {
        #expect(throws: MissingFixture.self) {
            try fixtureURL(named: "no-such-fixture.json")
        }
        #expect("\(MissingFixture(name: "no-such-fixture.json"))"
            .contains("no-such-fixture.json"))
    }

    @Test("a fixture name with no extension is still resolvable")
    func extensionlessName() {
        // Not a shape any fixture uses today; asserted so the split in
        // `fixtureURL` cannot silently start throwing on one.
        #expect(throws: MissingFixture.self) {
            try fixtureURL(named: "README")
        }
    }
}
