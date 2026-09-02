// AtelierLibraryPaths tests — where the Library root comes from (092 · S1, moved S4a
// and again in 096 review 4A).
//
// These moved here with the type, unchanged apart from the module they import: the
// seam is the same seam, and an assertion that had to change would have meant the
// move was not clean.
//
// Two jobs. The first is a regression fence: the App Group seam must not have moved
// the macOS root by a byte, and it must not have touched the `-library-root` /
// `ATELIER_LIBRARY_ROOT` escape hatch the bake-offs and scratch libraries depend on.
//
// The second is proving the iOS path without an iOS toolchain. The App Group work is
// two steps — read an identifier out of Info.plist, ask `FileManager` for that
// container — and only the second is genuinely platform-bound. So the identifier read
// takes its raw value as a parameter and the container-to-root step is
// `libraryRoot(under:)`, and both are exercised here on macOS. What is left untested
// until an iOS target exists is four lines of container lookup.
//
// The third, since 457, is the BUNDLE the identifier is read from. `Bundle.main` in a
// UI test is the XCTest runner, so the read takes a bundle, defaulted to `.main`; the
// cases below write a bundle to a temp directory — a directory with an `Info.plist` is
// one — and read a present, an absent and a blank key out of it. The default is pinned
// too: on this host `.main` carries no key, and `appGroupIdentifier()` must say exactly
// what `appGroupIdentifier(bundle: .main)` says.

import Foundation
import Testing

import AtelierLibraryPaths

@Suite("LibraryLocation (092 S1)")
struct LibraryLocationTests {

    private var applicationSupport: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        }
    }

    private func makeTempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryLocationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - macOS default root
    //
    // These two touch the REAL `~/Library/Application Support/ref-atelier/` — the
    // same directory the shipping app opens — because `swift test` is unsandboxed
    // and there is no way to assert the macOS contract without asking for it. That
    // is deliberate: `defaultRoot()` is idempotent and creates a directory the app
    // creates anyway, so the side effect is a no-op on any machine that has ever
    // run AtelierRefs. Everything that can be proven over a temp base is, below.

    @Test("on macOS the default root is still <Application Support>/ref-atelier/")
    func defaultRootIsUnderApplicationSupport() throws {
        let expected = try applicationSupport
            .appendingPathComponent("ref-atelier", isDirectory: true)
        let root = try LibraryLocation.defaultRoot()

        #expect(root == expected)
        #expect(isDirectory(root))
    }

    // MARK: - The platform-free seam

    @Test("libraryRoot(under:) names and creates the directory")
    func libraryRootCreatesUnderBase() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let root = try LibraryLocation.libraryRoot(under: base)

        #expect(root == base.appendingPathComponent("ref-atelier", isDirectory: true))
        #expect(root.hasDirectoryPath)
        #expect(isDirectory(root))
    }

    @Test("libraryRoot(under:) is idempotent — a second call opens the same directory")
    func libraryRootIsIdempotent() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try LibraryLocation.libraryRoot(under: base)
        // A file inside proves the second call adopted the directory rather than
        // replacing it — the app is launched more than once against the same library.
        let marker = first.appendingPathComponent("marker", isDirectory: false)
        try Data("x".utf8).write(to: marker)

        let second = try LibraryLocation.libraryRoot(under: base)

        #expect(second == first)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - The Info.plist identifier

    @Test("a configured App Group identifier passes through")
    func identifierPassesThrough() throws {
        let identifier = try LibraryLocation.appGroupIdentifier(
            rawValue: "group.sujenphea.AtelierRefs.dev")

        #expect(identifier == "group.sujenphea.AtelierRefs.dev")
    }

    @Test("a missing Info.plist key is a typed error, not a silent fallback")
    func missingIdentifierThrows() {
        #expect(throws: LibraryLocationError.appGroupIdentifierMissing(
            key: LibraryLocation.appGroupIdentifierKey)) {
            _ = try LibraryLocation.appGroupIdentifier(rawValue: nil)
        }
    }

    @Test("an empty Info.plist value is treated as missing")
    func emptyIdentifierThrows() {
        #expect(throws: LibraryLocationError.appGroupIdentifierMissing(
            key: LibraryLocation.appGroupIdentifierKey)) {
            _ = try LibraryLocation.appGroupIdentifier(rawValue: "")
        }
    }

    @Test("a whitespace-only Info.plist value is treated as missing")
    func blankIdentifierThrows() {
        // The shape an unsubstituted `$(ATELIER_APP_GROUP)` leaves behind when the
        // build setting is absent for a configuration.
        #expect(throws: LibraryLocationError.appGroupIdentifierMissing(
            key: LibraryLocation.appGroupIdentifierKey)) {
            _ = try LibraryLocation.appGroupIdentifier(rawValue: "  \n ")
        }
    }

    // MARK: - The bundle the identifier is read from (457)

    /// A bundle on disk whose Info.plist carries `value` under the App Group key, or
    /// carries no such key when `value` is nil. Flat — `Info.plist` at the bundle's
    /// root, the iOS shape — because that is the shape the share extension's and the
    /// UI-test bundle's plists take; a `Contents/` bundle reads the same way.
    private func makeBundle(identifier value: String?) throws -> (bundle: Bundle, base: URL) {
        let base = try makeTempBase()
        let url = base.appendingPathComponent("Fixture.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "test.fixture"]
        if let value { plist[LibraryLocation.appGroupIdentifierKey] = value }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: url))
        return (bundle, base)
    }

    @Test("a bundle carrying the key resolves its identifier")
    func bundleWithIdentifier() throws {
        let (bundle, base) = try makeBundle(identifier: "group.sujenphea.AtelierRefs.dev")
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(try LibraryLocation.appGroupIdentifier(bundle: bundle)
            == "group.sujenphea.AtelierRefs.dev")
    }

    @Test("a bundle without the key is the typed error — the runner's shape")
    func bundleWithoutIdentifier() throws {
        let (bundle, base) = try makeBundle(identifier: nil)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(throws: LibraryLocationError.appGroupIdentifierMissing(
            key: LibraryLocation.appGroupIdentifierKey)) {
            _ = try LibraryLocation.appGroupIdentifier(bundle: bundle)
        }
    }

    @Test("a bundle whose value is blank is treated as missing, as the raw parse is")
    func bundleWithBlankIdentifier() throws {
        let (bundle, base) = try makeBundle(identifier: " \n")
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(throws: LibraryLocationError.appGroupIdentifierMissing(
            key: LibraryLocation.appGroupIdentifierKey)) {
            _ = try LibraryLocation.appGroupIdentifier(bundle: bundle)
        }
    }

    /// The default is `.main` and nothing else — pinned by asking both ways on a host
    /// where `.main` is the test runner and carries no key. What `.main` resolves to is
    /// not this test's to change; that it is still the default is.
    @Test("no bundle argument means Bundle.main, whatever Bundle.main says")
    func defaultBundleIsMain() {
        let viaDefault = Result { try LibraryLocation.appGroupIdentifier() }
        let viaMain = Result { try LibraryLocation.appGroupIdentifier(bundle: .main) }

        switch (viaDefault, viaMain) {
        case let (.success(a), .success(b)):
            #expect(a == b)
        case let (.failure(a as LibraryLocationError), .failure(b as LibraryLocationError)):
            #expect(a == b)
            #expect(a == .appGroupIdentifierMissing(key: LibraryLocation.appGroupIdentifierKey))
        default:
            Issue.record("the default and the explicit .main read disagreed: \(viaDefault) vs \(viaMain)")
        }
    }

    /// On macOS the base is Application Support whoever asks, so a bundle that DOES
    /// carry an identifier changes nothing — the parameter is for the iOS branch, and
    /// the macOS root must not have moved by a byte.
    @Test("on macOS defaultRoot(bundle:) ignores the bundle")
    func defaultRootIgnoresBundleOnMacOS() throws {
        let (bundle, base) = try makeBundle(identifier: "group.sujenphea.AtelierRefs.dev")
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(try LibraryLocation.defaultRoot(bundle: bundle)
            == (try LibraryLocation.defaultRoot()))
    }

    // MARK: - The override branch, unchanged

    @Test("a relative override is a sibling under Application Support")
    func relativeOverrideIsSibling() throws {
        let name = "LibraryLocationTests-\(UUID().uuidString)"
        let expected = try applicationSupport.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: expected) }

        let root = try LibraryLocation.resolvedRoot(
            arguments: ["AtelierRefs", "-library-root", name],
            environment: [:])

        #expect(root == expected)
        #expect(isDirectory(root))
    }

    @Test("an absolute override is used verbatim")
    func absoluteOverrideIsVerbatim() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("scratch", isDirectory: true)

        let root = try LibraryLocation.resolvedRoot(
            arguments: ["AtelierRefs", "-library-root", target.path],
            environment: [:])

        #expect(root.standardizedFileURL == target.standardizedFileURL)
        #expect(isDirectory(root))
    }

    @Test("an empty override value is ignored")
    func emptyOverrideIsAbsent() throws {
        #expect(LibraryLocation.overrideValue(
            arguments: ["AtelierRefs", "-library-root", ""],
            environment: [:]) == nil)
        #expect(LibraryLocation.overrideValue(
            arguments: [],
            environment: [LibraryLocation.overrideEnvironmentKey: ""]) == nil)
    }

    @Test("a whitespace-only override value is ignored")
    func whitespaceOverrideIsAbsent() throws {
        #expect(LibraryLocation.overrideValue(
            arguments: ["AtelierRefs", "-library-root", "   "],
            environment: [:]) == nil)
        #expect(LibraryLocation.overrideValue(
            arguments: [],
            environment: [LibraryLocation.overrideEnvironmentKey: "\t\n "]) == nil)
    }

    @Test("no override at all resolves to exactly defaultRoot()")
    func noOverrideIsDefaultRoot() throws {
        #expect(LibraryLocation.overrideValue(arguments: ["AtelierRefs"], environment: [:]) == nil)

        let root = try LibraryLocation.resolvedRoot(arguments: ["AtelierRefs"], environment: [:])

        #expect(root == (try LibraryLocation.defaultRoot()))
    }

    @Test("the argument beats the environment variable")
    func argumentBeatsEnvironment() {
        let value = LibraryLocation.overrideValue(
            arguments: ["AtelierRefs", "-library-root", "from-argument"],
            environment: [LibraryLocation.overrideEnvironmentKey: "from-environment"])

        #expect(value == "from-argument")
    }

    @Test("the argument with no operand falls back to the environment")
    func danglingArgumentFallsBack() {
        // `-library-root` as the last argument has nothing after it — a trailing flag
        // must not read past the end of the array, and must not shadow the variable.
        #expect(LibraryLocation.overrideValue(
            arguments: ["AtelierRefs", "-library-root"],
            environment: [LibraryLocation.overrideEnvironmentKey: "from-environment"])
            == "from-environment")
        #expect(LibraryLocation.overrideValue(
            arguments: ["AtelierRefs", "-library-root"],
            environment: [:]) == nil)
    }
}
