//
//  FolderAccess.swift
//  AtelierRefs
//
//  The sandbox seam for a user-chosen folder the app must reach again on a
//  LATER launch (008 · F2, the foundation under H4/H5's off-device backup).
//
//  Everything an app-sandboxed process can normally touch is inside its own
//  container. A folder the user picks is granted by powerbox for that process
//  lifetime only — remembering it across launches requires a security-scoped
//  bookmark (entitlement `com.apple.security.files.bookmarks.app-scope`) and
//  bracketing every use in `startAccessingSecurityScopedResource()`.
//
//  Two protocols, each earning its keep:
//    • `FolderAccess` — what CONSUMERS depend on ("give me a usable URL, inside
//      a scope"). H5's backup engine takes one of these, so its tests can pass a
//      plain temp directory and never touch bookmarks or the sandbox at all.
//    • `BookmarkVault` — what `StoredFolderAccess` depends on. Creating a real
//      security-scoped bookmark needs a powerbox-granted URL, which a test
//      process cannot produce, so the Foundation calls sit behind this seam and
//      the persistence/staleness/error logic above them is fully unit-tested.
//

import Foundation

/// A failure reaching the chosen folder — each case maps to a distinct thing to
/// tell the user, which is why this is not one opaque error.
nonisolated enum FolderAccessError: Error, Equatable {
    /// No folder has been chosen yet (or it was cleared) — ask the user to pick.
    case noFolderChosen
    /// The bookmark no longer resolves: the folder was deleted, renamed beyond
    /// tracking, or lives on a volume that isn't mounted. Ask the user to re-pick.
    case bookmarkUnresolvable
    /// The bookmark resolved but the sandbox refused the security scope — the
    /// grant was revoked. Ask the user to re-pick.
    case accessDenied
}

/// Somewhere on disk the app may read and write, made reachable for the
/// duration of a call.
///
/// Conformers supply the three primitives; the `withAccess` brackets come from
/// the protocol extension below, so the `defer` that releases the scope is
/// written once rather than once per conformance.
protocol FolderAccess: Sendable {
    /// The folder's current URL, or a typed failure. Resolving does NOT grant
    /// access — use ``withAccess(_:)`` to actually touch the contents.
    func resolve() throws -> URL

    /// Grant access to a URL that ``resolve()`` returned.
    /// Throws ``FolderAccessError/accessDenied`` if the sandbox refuses.
    func beginAccess(to url: URL) throws

    /// Release a grant taken by ``beginAccess(to:)``. Must be safe to call
    /// exactly once per successful begin.
    func endAccess(to url: URL)
}

extension FolderAccess {
    /// Run `body` with the folder access-granted, releasing the scope
    /// afterwards even if `body` throws. The URL passed in is freshly resolved.
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        try beginAccess(to: url)
        defer { endAccess(to: url) }
        return try body(url)
    }

    /// The async form, for work that spans suspension points — an off-device
    /// backup copying thousands of files (008 · H5).
    ///
    /// A security scope is a property of the URL, not of the calling thread, so
    /// holding it across `await` is legitimate; what matters is that it is
    /// released exactly once, which the shared `defer` guarantees. The
    /// synchronous overload cannot serve here: a `body` that suspends would have
    /// its scope torn down at the first `await`, and every copy after that would
    /// fail with a permission error the user could do nothing about.
    func withAccess<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let url = try resolve()
        try beginAccess(to: url)
        defer { endAccess(to: url) }
        return try await body(url)
    }
}

/// Creates and resolves security-scoped bookmarks. Injectable because the real
/// implementation's inputs (powerbox-granted URLs) can't exist in a test.
protocol BookmarkVault: Sendable {
    /// Bookmark data that survives relaunch, for a URL the user just granted.
    func makeBookmark(for url: URL) throws -> Data
    /// Resolve bookmark data back to a URL. `isStale` means the OS produced a
    /// valid URL but wants the bookmark rewritten (the folder moved).
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
}

/// The real Foundation implementation.
///
/// Not unit-tested by design (see the file header): a test process can't obtain
/// a powerbox-granted URL, so `bookmarkData(options: .withSecurityScope)` has
/// nothing valid to bookmark. Verified by the manual backup runbook instead;
/// everything ABOVE this type is covered by tests through ``BookmarkVault``.
struct SecurityScopedBookmarkVault: BookmarkVault {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}

/// A ``FolderAccess`` backed by a bookmark persisted in `UserDefaults`.
///
/// Owns the whole lifecycle: remember a freshly chosen folder, resolve it on a
/// later launch, refresh the bookmark when the OS reports it stale, and forget
/// it when the user clears the target. Marked `@unchecked Sendable` for the same
/// reason `UserDefaults` use elsewhere is: the defaults object is thread-safe
/// and the stored properties are immutable after init.
final class StoredFolderAccess: FolderAccess, @unchecked Sendable {
    /// The persisted bookmark blob. One key: multi-library is deferred, and the
    /// destination namespaces by library id INSIDE the folder (008 H5), so a
    /// second key would buy nothing today.
    static let bookmarkKey = "AtelierBackupFolderBookmark"

    private let vault: any BookmarkVault
    private let defaults: UserDefaults

    init(vault: any BookmarkVault = SecurityScopedBookmarkVault(),
         defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
    }

    /// Whether a folder has been chosen. Cheap — does not resolve the bookmark,
    /// so a UI can call it per render without touching the disk or the volume.
    var hasFolder: Bool {
        defaults.data(forKey: Self.bookmarkKey) != nil
    }

    /// Remember `url` (just granted by the folder picker) as the target.
    /// Throws — and persists NOTHING — if the bookmark can't be made, so a
    /// failure can never leave a half-chosen target behind.
    func setFolder(_ url: URL) throws {
        let data = try vault.makeBookmark(for: url)
        defaults.set(data, forKey: Self.bookmarkKey)
    }

    /// Forget the target entirely.
    func clearFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    func resolve() throws -> URL {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            throw FolderAccessError.noFolderChosen
        }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try vault.resolve(data)
        } catch {
            // Deleted, renamed beyond tracking, or on an unmounted volume. The
            // stale bookmark is deliberately KEPT: a folder on a disconnected
            // drive resolves again once it's plugged in, and silently forgetting
            // the target would turn "plug your drive back in" into "set up your
            // backup again".
            throw FolderAccessError.bookmarkUnresolvable
        }
        if resolved.isStale {
            // The OS resolved it but wants it rewritten (the folder moved).
            // Refresh opportunistically; a failure here is not fatal — this
            // run's URL is still good, and the next run retries.
            try? refreshBookmark(for: resolved.url)
        }
        return resolved.url
    }

    func beginAccess(to url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw FolderAccessError.accessDenied
        }
    }

    func endAccess(to url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Re-bookmark a moved folder. Needs the security scope held, since making a
    /// bookmark is itself an access of the resource.
    private func refreshBookmark(for url: URL) throws {
        try beginAccess(to: url)
        defer { endAccess(to: url) }
        let data = try vault.makeBookmark(for: url)
        defaults.set(data, forKey: Self.bookmarkKey)
    }
}

/// A ``FolderAccess`` over a plain directory, with no bookmark and no sandbox
/// scope — the seam H5's engine tests use, and the shape a future
/// non-sandboxed context (a CLI, a test harness) would take.
struct DirectFolderAccess: FolderAccess {
    let url: URL

    init(url: URL) { self.url = url }

    func resolve() throws -> URL { url }

    /// No sandbox scope to take — a plain directory is already reachable.
    func beginAccess(to url: URL) throws {}
    func endAccess(to url: URL) {}
}
