// AtelierLibraryPaths — the default on-disk Library location (chunk 5; 092 · S1, moved
// S4a to AtelierCapture and again in 096 review 4A to here — see the manifest for why).
//
// Resolves the app's single Library root and ensures it exists, so the app hook has
// one place to build its `LibraryLayout` + `MediaStore` + `AppServices`. The root is
// always `<base>/ref-atelier/`; what differs per platform is only the BASE.
//
// **Why this left AtelierIngestion**, where S1 built it: this seam exists so the iOS
// share extension can find the library root, and in `AtelierIngestion` it could not.
// That package imported AppKit (`Input/DirectInputReader.swift`) and did not build for
// iOS at all — `.change-log/452` has since split that file, but at the time the one
// caller the App Group branch below was written for had no way to reach
// ``LibraryLocation/defaultRoot(bundle:)``. Nothing was broken by that — the seam simply
// had no caller on its own platform. A zero-dependency leaf that the extension, the
// companion, the UI-test runner and the Mac all link is where it ended up, and the Mac
// callers resolve exactly the root they always did.
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
// `libraryRoot(under:)`, `appGroupIdentifier(rawValue:)` and `appGroupIdentifier(bundle:)`
// are platform-free and both platforms route through them, leaving only the container
// lookup and the data-protection call inside `#if os(iOS)`.
//
// **Which bundle** (457; 098 · finding 10). The identifier is read from a bundle's
// Info.plist, and the bundle is a PARAMETER defaulted to `.main`, not a hard-coded
// `.main`: a UI test's `Bundle.main` is the XCTest runner, whose plist carries no such
// key, so `Tier2ShareUITests` could never resolve the App Group its own bundle had been
// given (455 recorded the failure). A caller that is not the app passes its own bundle;
// every caller that is the app — the companion, the share extension — passes nothing and
// gets exactly what it always got. The default is what keeps the app's behaviour
// unchanged, and the parameter is what makes it testable over a bundle written to a
// temp directory.
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
/// ``LibraryLocation/defaultRoot(bundle:)``. `Equatable` so tests assert the exact case.
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

    /// The App Group identifier from `bundle`'s Info.plist — `Bundle.main` unless a
    /// caller says otherwise (457).
    ///
    /// `Bundle.main` in an app extension is the EXTENSION's bundle, not the host app's
    /// — an extension gets no reading of its container app's plist — so the share
    /// extension needs its own copy of ``appGroupIdentifierKey``, fed by the same build
    /// setting. Two plists, one build setting, one identifier (092 · S4b). And
    /// `Bundle.main` in a UI test is the test RUNNER, which has no plist of ours at all
    /// — so a test passes `Bundle(for: Self.self)` and reads its own.
    ///
    /// The read is here and the parse is ``appGroupIdentifier(rawValue:)``; this only
    /// looks the key up and hands the value on, so the two cannot disagree about what a
    /// blank value means.
    public static func appGroupIdentifier(bundle: Bundle = .main) throws -> String {
        try appGroupIdentifier(
            rawValue: bundle.object(forInfoDictionaryKey: appGroupIdentifierKey) as? String)
    }

    /// The App Group identifier a raw Info.plist value amounts to.
    ///
    /// Takes the raw value as a parameter, with no default, so the failure paths are
    /// exercisable on macOS, where there is no App Group to misconfigure. The bundle read
    /// that feeds it is ``appGroupIdentifier(bundle:)``.
    ///
    /// Throws ``LibraryLocationError/appGroupIdentifierMissing(key:)`` when the key is
    /// absent or blank. A whitespace-only value is treated as absent for the same
    /// reason the `-library-root` override treats it that way: it is a misconfiguration
    /// that would otherwise resolve to something plausible-looking and wrong.
    public static func appGroupIdentifier(rawValue: String?) throws -> String {
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
    /// `bundle` is where the App Group identifier is read from on iOS, and is not
    /// consulted on macOS, where the base is Application Support whoever asks. It
    /// defaults to `.main` so every app caller resolves exactly what it always did; a
    /// UI test passes its own (457).
    ///
    /// Throws if the base can't be resolved or the directory can't be created
    /// (surfaced by the caller as an "open library failed" state).
    ///
    /// On iOS a nil container is a typed error, never a fallback to Application
    /// Support. Falling back would "work" in the app and silently give the extension a
    /// second, invisible root; what the user would see is captures that vanish. A
    /// missing container is a provisioning bug and should fail where it is fixable.
    public static func defaultRoot(bundle: Bundle = .main) throws -> URL {
        let root = try libraryRoot(under: defaultBase(bundle: bundle))
        try protectAtRest(root)
        return root
    }

    /// The container the Library lives inside — the only genuinely platform-specific
    /// step. `bundle` matters only on iOS; see ``defaultRoot(bundle:)``.
    private static func defaultBase(bundle: Bundle) throws -> URL {
        #if os(iOS)
        let identifier = try appGroupIdentifier(bundle: bundle)
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
    ///
    /// **Honoured in DEBUG builds only** (099 · 8A). A launch argument is the
    /// cheapest thing in the world to pass — Finder's Open-with, a `.command`
    /// file, a login item, an `open -a … --args` from any script the user runs —
    /// and this one silently redirects the app at a DIFFERENT LIBRARY. In a
    /// shipped build that is not a debugging affordance, it is a way for the app
    /// to open somewhere the user did not put their work. The constant survives
    /// in both configurations (it is the argument's NAME, and the DEBUG-only
    /// behaviour is asserted against it); what is DEBUG-only is
    /// ``overrideValue(arguments:environment:)`` reading it.
    public static let overrideArgument = "-library-root"

    /// The environment variable that overrides the Library root — the same value
    /// space as ``overrideArgument``, checked only when the argument is absent.
    ///
    /// **Unconditional, in every configuration, deliberately.** An environment
    /// variable is not reachable by a double-click: something has to set it in the
    /// process's environment, which means a shell, a test runner or an Xcode
    /// scheme. That is exactly the audience the escape hatch is for, and the
    /// macOS UI-test target (099 · P2) seeds its throwaway library through this
    /// key on a build it does not control the configuration of.
    public static let overrideEnvironmentKey = "ATELIER_LIBRARY_ROOT"

    /// The Library root to actually open: an override when one is supplied,
    /// otherwise ``defaultRoot(bundle:)`` over `Bundle.main`.
    ///
    /// The override is a THROWAWAY-library escape hatch for performance work and
    /// tests — it must never be reachable by accident, so with no argument and no
    /// environment variable this is exactly ``defaultRoot(bundle:)``, byte for byte.
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
        // The argument arm is DEBUG-only (099 · 8A) — see ``overrideArgument``.
        // In a Release build `arguments` is not consulted at all, so a passed
        // `-library-root` is not "ignored after parsing", it is never parsed.
        #if DEBUG
        let fromArgument: String? = arguments.firstIndex(of: overrideArgument)
            .map { $0 + 1 }
            .flatMap { arguments.indices.contains($0) ? arguments[$0] : nil }
        #else
        let fromArgument: String? = nil
        #endif
        let raw = fromArgument ?? environment[overrideEnvironmentKey]
        // Spelled here rather than `AtelierCore.TextRules.nonBlank`: this package has no
        // dependencies by charter (see the manifest), and a leaf cannot import the rule.
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
