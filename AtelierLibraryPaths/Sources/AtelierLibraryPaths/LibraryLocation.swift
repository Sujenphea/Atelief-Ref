// AtelierCapture — the default on-disk Library location (chunk 5; 092 · S1, moved S4a)
//
// Resolves the app's single Library root and ensures it exists, so the app hook has
// one place to build its `LibraryLayout` + `MediaStore` + `AppServices`. The root is
// always `<base>/ref-atelier/`; what differs per platform is only the BASE.
//
// **Why this is in AtelierCapture and not AtelierIngestion**, where S1 built it: this
// seam exists so the iOS share extension can find the library root, and in
// `AtelierIngestion` it could not. That package imports AppKit
// (`Input/DirectInputReader.swift`) and does not build for iOS at all, so the one
// caller the App Group branch below was written for had no way to reach
// ``LibraryLocation/defaultRoot()``. Nothing was broken by that — the seam simply had
// no caller on its own platform. This package is transport-free and platform-free by
// construction, already builds for iOS 26, and is already on the extension's link
// line; it is where ``InboxLayout`` went in S2 for the same reason, and the AppKit
// boundary has now pulled a type out of AtelierIngestion twice. The macOS callers
// import AtelierCapture and resolve exactly the root they always did.
//
// On macOS the base is Application Support. In a sandboxed app `FileManager` returns
// the per-app container's Application Support
// (`~/Library/Containers/<id>/Data/Library/Application Support/`), which is writable
// without any extra entitlement.
//
// On iOS that path is per-process: the app and its share extension are separate
// processes with separate containers, so a capture written by the extension into
// Application Support would land somewhere the app cannot see. The base there is the
// App Group container instead (091 · D3), named by an Info.plist key so the value
// travels with the entitlement that grants it rather than being frozen into this
// package.
//
// **The macOS library deliberately does NOT move into a macOS App Group.** It would
// look tidier to have one rule for both platforms, and it would cost a data migration
// of every existing library for zero functional gain — macOS has no share extension
// to share with. The container divergence is the point, not an inconsistency to iron
// out (092 · S1).
//
// The seam is shaped so almost all of it is testable without an iOS toolchain:
// `libraryRoot(under:)` and `appGroupIdentifier(rawValue:)` are platform-free and both
// platforms route through them, leaving only the container lookup and the
// data-protection call inside `#if os(iOS)`.
//
// **And that residue is untested, deliberately** (R6 · issue 12). Three things have
// run exactly once each, by hand, on a simulator during S4b-i and never since: the
// `containerURL(forSecurityApplicationGroupIdentifier:)` lookup in `defaultBase()`,
// the ``LibraryLocationError/appGroupContainerUnavailable(identifier:)`` it throws
// when that returns nil, and the `completeUntilFirstUserAuthentication` attribute
// `protectAtRest(_:)` sets. There is no iOS test target in this package and none was
// added for them.
//
// The position is considered rather than deferred, and the reason is that a test of
// this residue would assert nothing about this code. What is left inside the `#if` is
// three Apple API calls and a `guard`: a unit test around them would stand up a fake
// `FileManager` and then assert that `FileManager` does what `FileManager` does —
// which is a test of Foundation, kept green by this package, and it would keep passing
// through exactly the failures that matter. The two that matter are a container the
// entitlement does not actually grant and a file the phone will not open, and neither
// is reachable from a process that is not a real, provisioned, LOCKED device. The
// protection class in particular means nothing anywhere else: the whole point of
// `completeUntilFirstUserAuthentication` over the inherited default is what happens to
// an open() before the first unlock after a boot, and a simulator, a Mac and a unit
// test all answer that question the same wrong way.
//
// What is tested is everything the residue is wrapped in, and that is not an
// accident — it is why the platform-specific part was made this small. The identifier
// parse, its blank and whitespace cases, the root's name and creation, the override
// argument and environment variable and their precedence all have tests, and all of
// them are the same code on both platforms. What remains is a call and a `guard`, and
// the honest coverage claim for it is one manual run on a simulator, recorded here
// rather than implied by silence.

import Foundation

/// A typed failure resolving the iOS App Group container. Both cases mean the same
/// class of bug — the App Group is not wired up — and both are fatal by design: see
/// ``LibraryLocation/defaultRoot()``. `Equatable` so tests assert the exact case.
public enum LibraryLocationError: Error, Equatable {
    /// The calling process's own bundle carries no
    /// ``LibraryLocation/appGroupIdentifierKey`` value, or carries a blank one.
    /// Payload: the key that was looked up.
    case appGroupIdentifierMissing(key: String)
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returned nil — the
    /// identifier is spelled right but the entitlement doesn't grant it. Payload: the
    /// identifier that was asked for.
    case appGroupContainerUnavailable(identifier: String)
}

/// The default Library location on disk (chunk 5). A namespace — `static` only.
public enum LibraryLocation {
    /// The Info.plist key naming the App Group whose container holds the Library on
    /// iOS. The value is `$(ATELIER_APP_GROUP)`, a per-configuration build setting, so
    /// the dev and release builds get `group.sujenphea.AtelierRefs.dev` and
    /// `group.sujenphea.AtelierRefs` respectively — mirroring the bundle-ID split the
    /// app already has, and keeping the two builds' libraries apart.
    ///
    /// A key rather than a constant here or a caller parameter: the identifier has to
    /// agree with the entitlement file that grants it and with the extension that
    /// shares it, and an Info.plist value fed by a build setting is the one place all
    /// three can read from. (The plist and build-setting wiring is 092 · S4b.)
    public static let appGroupIdentifierKey = "AtelierAppGroupIdentifier"

    /// The App Group identifier from `Bundle.main`'s Info.plist.
    ///
    /// `Bundle.main` in an app extension is the EXTENSION's bundle, not the host app's
    /// — an extension gets no reading of its container app's plist — so the share
    /// extension needs its own copy of ``appGroupIdentifierKey``, fed by the same build
    /// setting. Two plists, one build setting, one identifier (092 · S4b).
    ///
    /// Takes the raw value as a parameter — defaulted to the real `Bundle.main` read —
    /// so the failure paths are exercisable on macOS, where there is no App Group to
    /// misconfigure.
    ///
    /// Throws ``LibraryLocationError/appGroupIdentifierMissing(key:)`` when the key is
    /// absent or blank. A whitespace-only value is treated as absent for the same
    /// reason the `-library-root` override treats it that way: it is a misconfiguration
    /// that would otherwise resolve to something plausible-looking and wrong.
    public static func appGroupIdentifier(
        rawValue: String? = Bundle.main
            .object(forInfoDictionaryKey: LibraryLocation.appGroupIdentifierKey) as? String
    ) throws -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            throw LibraryLocationError.appGroupIdentifierMissing(key: appGroupIdentifierKey)
        }
        return trimmed
    }

    /// `<base>/ref-atelier/` — created if it does not yet exist, and returned as a
    /// directory URL. Idempotent.
    ///
    /// Platform-free on purpose: this is the whole of "where the Library sits inside a
    /// container", and both platforms call it, so the naming and creation behaviour
    /// cannot drift between them.
    public static func libraryRoot(under base: URL) throws -> URL {
        let root = base.appendingPathComponent("ref-atelier", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    /// The Library root — `<Application Support>/ref-atelier/` on macOS, the App Group
    /// container's `ref-atelier/` on iOS — created if it does not yet exist, and
    /// returned as a directory URL.
    ///
    /// Throws if the base can't be resolved or the directory can't be created
    /// (surfaced by the caller as an "open library failed" state).
    ///
    /// On iOS a nil container is a typed error, never a fallback to Application
    /// Support. Falling back would "work" in the app and silently give the extension a
    /// second, invisible root; what the user would see is captures that vanish. A
    /// missing container is a provisioning bug and should fail where it is fixable.
    public static func defaultRoot() throws -> URL {
        let root = try libraryRoot(under: defaultBase())
        try protectAtRest(root)
        return root
    }

    /// The container the Library lives inside — the only genuinely platform-specific
    /// step.
    private static func defaultBase() throws -> URL {
        #if os(iOS)
        let identifier = try appGroupIdentifier()
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw LibraryLocationError.appGroupContainerUnavailable(identifier: identifier)
        }
        return container
        #else
        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        #endif
    }

    /// Pin the Library root's data-protection class on iOS; a no-op elsewhere.
    ///
    /// Explicit rather than inherited because the inherited default can be
    /// `completeUnlessOpen`, under which a background inbox drain that starts while the
    /// phone is locked cannot open the SQLite files at all — a failure that reproduces
    /// only on a real locked device, never in the simulator or in tests.
    /// `completeUntilFirstUserAuthentication` still encrypts at rest but keeps the
    /// files openable after the first unlock following a boot (092 · S1, the gate).
    private static func protectAtRest(_ root: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path)
        #endif
    }

    /// The launch argument that overrides the Library root, e.g.
    /// `AtelierRefs -library-root bakeoff`.
    public static let overrideArgument = "-library-root"

    /// The environment variable that overrides the Library root — the same value
    /// space as ``overrideArgument``, checked only when the argument is absent.
    public static let overrideEnvironmentKey = "ATELIER_LIBRARY_ROOT"

    /// The Library root to actually open: an override when one is supplied,
    /// otherwise ``defaultRoot()``.
    ///
    /// The override is a THROWAWAY-library escape hatch for performance work and
    /// tests — it must never be reachable by accident, so with no argument and no
    /// environment variable this is exactly ``defaultRoot()``, byte for byte.
    ///
    /// The value is interpreted two ways, because the app is sandboxed and an
    /// arbitrary absolute path is NOT writable from inside its container:
    ///   • a RELATIVE value is a sibling directory name under Application Support
    ///     (`<Application Support>/<value>/`) — always sandbox-legal, and the form
    ///     the app itself should be launched with;
    ///   • an ABSOLUTE path is used verbatim, for unsandboxed callers (SwiftPM
    ///     tests, tools) that can legally write outside a container.
    ///
    /// An empty / whitespace-only value is ignored (treated as absent) rather than
    /// resolving to Application Support itself.
    ///
    /// The override branch stays on Application Support on BOTH platforms and is
    /// otherwise untouched by the App Group work: a throwaway library is by definition
    /// not shared with an extension, and the bake-offs and tests that depend on this
    /// path must keep resolving identically (092 · S1).
    public static func resolvedRoot(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let override = overrideValue(arguments: arguments, environment: environment) else {
            return try defaultRoot()
        }
        let root: URL
        if override.hasPrefix("/") {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            root = base.appendingPathComponent(override, isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    /// The raw override value — the argument's operand if present, else the
    /// environment variable — trimmed, with empty treated as absent.
    public static func overrideValue(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fromArgument: String? = arguments.firstIndex(of: overrideArgument)
            .map { $0 + 1 }
            .flatMap { arguments.indices.contains($0) ? arguments[$0] : nil }
        let raw = fromArgument ?? environment[overrideEnvironmentKey]
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
