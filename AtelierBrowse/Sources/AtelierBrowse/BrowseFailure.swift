// AtelierBrowse — one sentence per failure class (093 § 7, 098 · finding 9).
//
// 093 § 7 asked for this by name: a missing App Group is a typed FATAL error by design
// (092 · S1 · decision 3), so that a provisioning bug fails where it is fixable rather
// than silently writing a library somewhere else — and nothing rendered it. This is the
// mapping from those typed errors to what a person holding a phone is told.
//
// It lived as a `static func` on the app's `LibraryStore`, where nothing could run it.
// The sentences are the part worth testing: they are the entire user-facing consequence
// of an error class, they are load-bearing in exactly the situation where the app is
// otherwise blank, and a `default` arm quietly swallowing a case it should have named is
// invisible until someone is holding the broken phone.
//
// **What the wording commits to.** Where a failure is a SETUP problem the sentence says
// so ("This build is missing its App Group"), because the person seeing it on a
// development build can fix it and the person seeing it on a shipped one has told us
// something precise. Where it is not, the sentence does not speculate: the captures are
// still on disk in every one of these cases, and a phone cannot tell a corrupt database
// from a full disk without asking questions it has no way to ask.

import AtelierCore
import AtelierLibraryPaths
import Foundation

/// How the phone words a failure. A namespace — `static` only.
public enum BrowseFailure {
    /// One sentence per failure class. The typed payloads stay in the error; a person
    /// holding a phone is told what is wrong and, where it is actionable, that it is a
    /// setup problem rather than their library being gone.
    public static func message(for error: Error) -> String {
        switch error {
        case LibraryLocationError.appGroupIdentifierMissing:
            // The bundle carries no `AtelierAppGroupIdentifier`, or a blank one. A build
            // problem, and the only one of these a user could usefully report verbatim.
            "This build is missing its App Group. The library can't be opened."
        case LibraryLocationError.appGroupContainerUnavailable:
            // The identifier is spelled right and the entitlement does not grant it.
            "The App Group container isn't available. The library can't be opened."
        case let error as AtelierError:
            switch error {
            // The only `.notFound` browse can reach is a collection: `feed(for:)` throws
            // it for an absent collection, and a missing ITEM is a `nil` rather than a
            // throw, precisely so the two get different sentences.
            case .notFound: "That collection is no longer in the library."
            // Every other `AtelierError` is a write-side validation case or a collapsed
            // GRDB failure. Browse makes no writes (091 · D1), so reaching one of these
            // means the read itself failed, and there is nothing a user can do about it.
            default: "The library couldn't be read."
            }
        default:
            // Includes `BrowseStore.LibraryUnavailable`, a filesystem error from opening
            // the pool, and a migration failure. All of them mean the same thing to the
            // person looking at the screen.
            "The library couldn't be opened."
        }
    }
}
