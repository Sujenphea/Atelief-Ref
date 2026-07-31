// AtelierIngestion — the stable name a library answers to (008 · H5)
//
// An off-device backup lands in `<target>/<library-id>/`, so the library needs
// an identity that is stable across launches and independent of where it sits.
// The Library root's PATH cannot serve: it is inside the app's sandbox
// container, which changes if the app is reinstalled or the container is
// migrated, and the `-library-root` override makes it deliberately relocatable.
//
// The identity is therefore a small file at the Library root rather than a
// column in the database. Two reasons, both about restore: restoring a snapshot
// replaces `library.sqlite` wholesale, and an id living inside it would come
// back as whatever the snapshot's id was — so the SAME library could start
// writing to a different backup folder after a restore, silently orphaning
// everything already copied. A file beside the database survives every
// restore path untouched, which is exactly the property "which library is this"
// needs.

import Foundation

/// The stable identifier of a Library root — the directory name its off-device
/// backup lives under. A namespace: `static` only.
public enum LibraryIdentity {

    /// The file at the Library root holding the identifier.
    ///
    /// No extension and no dot prefix: it is a real artifact of the library that
    /// a user poking at the folder should be able to see and read, and hiding it
    /// would only make a support conversation harder.
    public static let fileName = "library-id"

    /// A stored identifier that isn't usable.
    public enum IdentityError: Error, Equatable {
        /// The id file exists but doesn't hold a well-formed identifier.
        case malformed(String)
    }

    /// The identifier of the library at `root`, creating and persisting one on
    /// first call.
    ///
    /// A malformed existing file is a hard error rather than an occasion to mint
    /// a replacement. Silently re-minting would point the next backup at a fresh,
    /// empty destination directory beside the real one — every blob copied
    /// again, the previous copy stranded and never updated — and the user's only
    /// clue would be the folder quietly doubling in size. Failing loudly keeps
    /// that a decision someone makes on purpose.
    public static func resolve(root: URL) throws -> String {
        let url = root.appendingPathComponent(fileName, isDirectory: false)

        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isWellFormed(trimmed) else { throw IdentityError.malformed(trimmed) }
            return trimmed
        }

        let minted = makeIdentifier()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // `.withoutOverwriting` makes the create exclusive, so two processes
            // racing on first launch cannot each believe they minted the id.
            // Deliberately NOT combined with `.atomic`: that writes a temp file
            // and renames it into place, which overwrites — the two options want
            // opposite things, and exclusivity is the one that matters here.
            try Data(minted.utf8).write(to: url, options: .withoutOverwriting)
            return minted
        } catch {
            // Lost the race (or the file appeared between our read and our
            // write): whatever is on disk now is authoritative, not our mint.
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { throw error }
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isWellFormed(trimmed) else { throw IdentityError.malformed(trimmed) }
            return trimmed
        }
    }

    /// Whether `id` is a usable identifier: exactly 16 lowercase hex characters.
    ///
    /// The rule is strict because this string becomes a PATH COMPONENT under a
    /// folder the user chose. Restricting it to `[0-9a-f]` rules out traversal
    /// (`..`, `/`), separators, whitespace, and — since macOS filesystems are
    /// case-insensitive by default — two ids that differ only in case and would
    /// collide into one directory.
    public static func isWellFormed(_ id: String) -> Bool {
        // An explicit literal set, not `Character.isHexDigit`: that property is
        // true for Unicode variants (fullwidth "７" and friends) which are legal
        // in a filename but are not what we mint, and letting them through would
        // mean an id that round-trips as a directory name nobody can type.
        id.count == length && id.allSatisfy(hexDigits.contains)
    }

    /// Mint a fresh identifier: the first 16 hex characters of a UUID.
    ///
    /// 64 bits, which is not a UUID's 122 — deliberately. This only has to
    /// distinguish the handful of libraries one person might back up into one
    /// folder, and it is read as a directory name by humans; a full dashed UUID
    /// buys collision resistance nobody needs at the cost of a name nobody can
    /// scan.
    static func makeIdentifier() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(length))
    }

    /// Characters in a well-formed identifier.
    private static let length = 16

    /// The only characters a well-formed identifier may contain.
    private static let hexDigits = Set("0123456789abcdef")
}
