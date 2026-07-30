//
//  BackupTarget.swift
//  AtelierRefs
//
//  008 · H4 — the rules and words for the off-device backup destination, kept
//  free of AppKit and SwiftUI so all of it is directly unit-testable. The view
//  supplies layout; this supplies the facts. (Same split as `CaptureCopy`, for
//  the same reason: prose and rules duplicated across surfaces drift.)
//

import Foundation

/// Why a folder the user picked can't serve as the backup target.
nonisolated enum BackupTargetRejection: Error, Equatable {
    /// The chosen folder IS the library, or sits inside it. Backing the library
    /// up into itself would copy blobs into the tree being enumerated and grow
    /// without bound — and it defeats the point, since the whole reason for an
    /// off-device copy is surviving the loss of this one.
    case insideLibrary
}

nonisolated enum BackupTarget {

    // MARK: - Choosing

    /// Vet a freshly picked folder. `nil` means it is usable.
    ///
    /// `libraryRoot` is optional because the Library may not be open yet; with
    /// nothing to compare against we cannot claim a conflict, so the choice
    /// stands. (Not a real path in practice — Settings is unreachable before
    /// bootstrap — but returning "rejected" on unknown would be a lie.)
    static func rejection(choosing target: URL, libraryRoot: URL?) -> BackupTargetRejection? {
        guard let libraryRoot else { return nil }
        return isSelfOrDescendant(target, of: libraryRoot) ? .insideLibrary : nil
    }

    /// Whether `url` is `ancestor` itself or lives underneath it.
    ///
    /// Compared by path COMPONENT, never by string prefix: `/Vol/Library2` has
    /// `/Vol/Library` as a string prefix but is a sibling, and rejecting it would
    /// block a perfectly good target. Symlinks are resolved and the path
    /// standardized first so `~/Backups/../Backups` and a symlinked volume path
    /// can't slip past.
    ///
    /// Comparison is case-INSENSITIVE, matching APFS's default. On a
    /// case-sensitive volume this is stricter than the filesystem — it can reject
    /// a folder that is technically distinct. That is the safe direction to err:
    /// the cost is re-picking a folder, versus a backup that eats itself.
    static func isSelfOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let target = normalizedComponents(url)
        let root = normalizedComponents(ancestor)
        guard root.count <= target.count else { return false }
        return zip(target, root).allSatisfy {
            $0.compare($1, options: .caseInsensitive) == .orderedSame
        }
    }

    private static func normalizedComponents(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    // MARK: - Words

    /// What to tell the user about a rejected choice.
    static func message(for rejection: BackupTargetRejection) -> String {
        switch rejection {
        case .insideLibrary:
            return "That folder is inside your library, so it can't hold the "
                + "backup. Choose a folder on another drive."
        }
    }

    /// What to tell the user about a target that can't be reached right now.
    /// Each case names a DIFFERENT next action — which is the whole reason
    /// ``FolderAccessError`` has three cases instead of being one opaque error.
    static func message(for error: FolderAccessError) -> String {
        switch error {
        case .noFolderChosen:
            return "No backup folder chosen yet."
        case .bookmarkUnresolvable:
            return "Can't find the backup folder. If it's on an external drive, "
                + "reconnect it — otherwise choose it again."
        case .accessDenied:
            return "macOS denied access to the backup folder. Choose it again to "
                + "restore permission."
        }
    }

    /// Shown when remembering a folder fails outright — a bookmark that can't be
    /// made at all, which leaves NO target behind (`StoredFolderAccess.setFolder`
    /// persists nothing on failure), so the honest instruction is to retry.
    static let couldNotRemember =
        "Couldn't remember that folder. Try choosing it again."

    /// The standing explanation under the folder row.
    static let explainer =
        "Backups copy your images and database here. Snapshots (File ▸ Snapshot "
        + "Now) live inside the library and won't survive losing this Mac — an "
        + "off-device folder will."
}
