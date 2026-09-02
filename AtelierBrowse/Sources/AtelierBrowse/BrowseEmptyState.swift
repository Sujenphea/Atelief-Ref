// AtelierBrowse — one sentence per empty grid (093 § 7, 098 · P6).
//
// The companion to `BrowseFailure`, and it exists for the same reason: 093 § 7 lists
// "empty and error states" among the things it deliberately did not design, 098 brings
// them into scope, and the DECIDABLE half of a screen with nothing on it is which of
// several different nothings it is.
//
// **There were four of them and the app drew one.** `ContentView.EmptyNotice` said
// "Nothing here yet / Anything you share arrives in Unsorted" for every empty grid, which
// is the right sentence for exactly one of the four and is wrong in three ways elsewhere:
//
//   · on a phone that has never been shared to, it is a statement about a mechanism the
//     user has not used yet, phrased as though they had;
//   · in a collection pushed off the switcher, it points at a DIFFERENT collection, so
//     the answer to "why is this empty" is a fact about somewhere else;
//   · in a collection that holds only subfolders, it is drawn UNDER a row of chips
//     containing exactly the pictures it says are missing — the one case the old
//     condition (`items.isEmpty && subcollections.isEmpty`) did not even reach, so that
//     screen had no sentence at all and rendered a panel of nothing under a chip row.
//
// **Why the discriminator is "is this Unsorted" and not "is this the root screen".** The
// root screen's collection is whatever the switcher last chose (`BrowseStore.
// rootCollectionID` is `var`), so `isRoot` answers a question about the navigation stack
// and this one is about the library: Unsorted is where every share lands (092 · S3), and
// that is the only thing that makes "anything you share arrives here" true.
//
// **And "the library is empty" is knowable cheaply.** Every item lives in a collection, so
// if Unsorted is empty and Unsorted is the only collection there is, there is nothing
// anywhere — no extra read, off a tree the switcher has already loaded. The one thing it
// cannot see is an ARCHIVED asset, which the feed hides (091 · D1 leaves archived out of
// v1 entirely); a library holding nothing but archived assets reports itself empty, which
// is what the phone shows either way and why no sentence here promises the library is
// *empty* rather than that there is nothing *here*.

import Foundation

/// Which kind of nothing a grid is showing, or `nil` when it is showing something.
///
/// A namespace of cases plus one resolver, deliberately not a view model: the app owns the
/// drawing and this owns the decision, which is the same split `BrowseFailure` makes.
public enum BrowseEmptyState: String, Equatable, Sendable, CaseIterable {
    /// Nothing has ever been captured on this phone or synced back to it.
    case emptyLibrary
    /// Unsorted is empty, but the library is not — everything has been filed.
    case emptyUnsorted
    /// A collection with nothing in it. Filling it is Mac work (091 · D1).
    case emptyCollection
    /// A collection whose pictures are all one level down. The chips are above; this is
    /// the space under them.
    case onlySubcollections

    /// What this grid is, from what the feed loaded.
    ///
    /// - Parameters:
    ///   - isUnsorted: whether this collection is the one every share lands in.
    ///   - itemCount: direct members the grid will draw.
    ///   - subcollectionCount: immediate children, drawn as chips above the grid.
    ///   - libraryCollectionCount: how many collections exist in the whole library,
    ///     Unsorted included — `BrowseStore.collectionCount`. Only consulted when
    ///     `isUnsorted` and there is nothing to draw, and only to tell the first launch
    ///     from a tidy one.
    /// - Returns: `nil` when the grid has something to show, and the `nil` is the point —
    ///   a caller writes `if let empty = …` rather than restating the emptiness test at
    ///   the call site, which is how the fourth case went missing in the first place.
    public static func resolve(
        isUnsorted: Bool,
        itemCount: Int,
        subcollectionCount: Int,
        libraryCollectionCount: Int
    ) -> BrowseEmptyState? {
        if itemCount > 0 { return nil }
        // Subfolders first: a collection with chips and no direct items is not empty to
        // the person looking at it, and telling them "nothing here yet" over a row of
        // folders they can see is the sentence contradicting the screen.
        if subcollectionCount > 0 { return .onlySubcollections }
        guard isUnsorted else { return .emptyCollection }
        return libraryCollectionCount <= 1 ? .emptyLibrary : .emptyUnsorted
    }

    /// The heading. Short, and a statement of what is true rather than an instruction.
    public var title: String {
        switch self {
        case .emptyLibrary: "Nothing saved yet"
        case .emptyUnsorted: "Unsorted is empty"
        case .emptyCollection: "This collection is empty"
        case .onlySubcollections: "Nothing here directly"
        }
    }

    /// The second line: the one fact the heading does not carry.
    ///
    /// Each names the mechanism that would change the screen, because that is the only
    /// useful thing an empty screen can say — and none of them names a control, since the
    /// phone has no verb that fills a collection (091 · D1).
    public var detail: String {
        switch self {
        case .emptyLibrary:
            "Share a picture or a page to Atelier and it arrives here."
        case .emptyUnsorted:
            "Everything you share lands here first. What's filed is in the other collections."
        case .emptyCollection:
            "Collections are filled on your Mac."
        case .onlySubcollections:
            "This collection's pictures are in the folders above."
        }
    }
}
