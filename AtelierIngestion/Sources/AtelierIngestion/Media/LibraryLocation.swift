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
}
