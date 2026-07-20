// AtelierIngestion — the default on-disk Library location (chunk 5)
//
// Resolves the app's single Library root under Application Support and ensures it
// exists, so the app hook has one place to build its `LibraryLayout` + `MediaStore`
// + `AppServices`. In a sandboxed app `FileManager` returns the per-app container's
// Application Support (`~/Library/Containers/<id>/Data/Library/Application Support/`),
// which is writable without any extra entitlement.

import Foundation

/// The default Library location on disk (chunk 5). A namespace — `static` only.
public enum LibraryLocation {
    /// The Library root — `<Application Support>/ref-atelier/` — created if it
    /// does not yet exist, and returned as a directory URL.
    ///
    /// Throws if Application Support can't be resolved or the directory can't be
    /// created (surfaced by the caller as an "open library failed" state).
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let root = base.appendingPathComponent("ref-atelier", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
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
