// AtelierIngestion — what a backup folder actually contains (008 · H5c)
//
// Backing up is a lookup: this library's id names the directory to write into.
// RESTORING cannot be, and getting that backwards is the one mistake that makes
// the whole feature useless.
//
// The case restore exists for is "my Mac died". The replacement Mac opens a
// fresh library, which mints a fresh `LibraryIdentity` — an id that has never
// appeared in the backup folder. Looking under the LOCAL id would find nothing
// and report an empty folder while the user's entire library sat one directory
// away. So restore DISCOVERS: it reads what is in the target and lets the user
// point at it. The backup's id names the directory, never the restorer's.
//
// A directory only counts as a backup if it holds a parseable manifest AND a
// database. The manifest is a run's commit record (`BackupRunner` writes it
// last), so its absence means the run that made that directory never finished —
// offering it as a restore candidate would be offering an unknown fraction of a
// library as if it were the whole thing.

import Foundation

/// One restorable library backup found inside a target folder.
public struct BackupSource: Sendable, Equatable {
    /// Where it lives — already namespaced by the BACKUP's library id.
    public let layout: BackupLayout
    /// Its commit record: when it completed, how big it is, what wrote it.
    public let manifest: BackupManifest

    public init(layout: BackupLayout, manifest: BackupManifest) {
        self.layout = layout
        self.manifest = manifest
    }

    /// The id of the library this backs up — the directory name, and the
    /// identity a library restoring from it adopts.
    public var libraryID: String { layout.libraryID }

    /// When the backup run that produced this finished.
    public var completedAt: Date { manifest.completedAt }
}

/// Reads a backup target folder and reports the complete backups in it.
/// A namespace: `static` only.
public enum BackupCatalog {

    /// Every complete library backup directly inside `target`, newest first.
    ///
    /// Deliberately shallow — one level, no recursion. The layout puts backups
    /// at `<target>/<library-id>/` and nowhere else, so a deep walk could only
    /// find things that are not backups (or the same backup nested inside a copy
    /// of the folder) while turning a cheap directory read into a full tree walk
    /// on what may be an iCloud volume where every stat is a network call.
    ///
    /// Never throws: an unreadable target, a directory that isn't a backup, a
    /// manifest that won't parse — all mean "nothing restorable here", which the
    /// caller has to handle anyway. A hard error would only turn one unrelated
    /// stray folder into a total refusal.
    public static func sources(in target: URL) -> [BackupSource] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: target, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var found: [BackupSource] = []
        for entry in entries {
            // The name must be a well-formed identity. That is not decoration:
            // it is the same validation that keeps an id from being a path
            // component it shouldn't be, applied to a name that came from the
            // filesystem rather than from us.
            let id = entry.lastPathComponent
            guard LibraryIdentity.isWellFormed(id),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let layout = BackupLayout(target: target, libraryID: id)
            guard fm.fileExists(atPath: layout.database.path),
                  let manifest = try? BackupManifest.read(from: layout.manifest)
            else { continue }

            found.append(BackupSource(layout: layout, manifest: manifest))
        }
        // Newest first: with several to choose from, the most recent is what
        // someone almost always wants, and it should not be a scroll away.
        return found.sorted { $0.completedAt > $1.completedAt }
    }
}
