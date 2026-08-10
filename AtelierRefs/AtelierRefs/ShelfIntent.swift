//
//  ShelfIntent.swift
//  AtelierRefs
//
//  023 · A3 — the one place that decides what the archive verb MEANS for a
//  selection: **archive, unless every target is already archived, in which case
//  unarchive.**
//
//  That is deliberately the same rule ⌘D already uses for the star (011 · U5),
//  stated once here so a reader does not have to reverse-engineer it: a MIXED
//  selection CONVERGES rather than flipping each item. Converging is the only
//  outcome a user can predict without inspecting every tile, and a second press
//  is still the inverse, so the verb reads as a toggle even though it is not a
//  per-item one. Inventing a second rule for archive when the app already has
//  one for favorites would be two conventions to remember.
//
//  It gets a file of its own for the reason `DeleteIntent` (022 · D1) does: four
//  surfaces consume it — the collection grid, the search results grid, the item
//  detail page and a Space board — and "the verb means the same thing
//  everywhere" has to be a property of the CODE rather than of four remembered
//  conventions. Pure and SwiftUI-free, so the whole matrix is pinned by tests
//  without a view or an `NSEvent`.
//
//  **There is deliberately no `surface` parameter.** It looks like there should
//  be one — the shelf unarchives, a collection archives — but the surface is
//  already implied by the data: a browsing read hides archived items (A1), so a
//  collection selection is all-unarchived by construction, and the shelf is
//  all-archived by construction. A surface argument would be a second source of
//  truth for the same fact, free to disagree with the first, and the case where
//  it disagreed is exactly the case that matters (a selection left stale by a
//  change underneath it).
//

import AppKit

/// What the archive verb should do for a set of targets (023 · A3), with the
/// number it acts on so a menu can title itself.
nonisolated enum ShelfVerb: Equatable {
    /// Put `count` items on the shelf.
    case archive(count: Int)
    /// Take `count` items off it.
    case unarchive(count: Int)

    /// How many items the verb acts on.
    var count: Int {
        switch self {
        case let .archive(n), let .unarchive(n): n
        }
    }

    /// The menu title, counted the way every other grid verb counts — a bare
    /// verb for one item, a parenthesised count for more, matching
    /// "Delete (3)" / "Remove from Collection (3)".
    var title: String {
        let suffix = count > 1 ? " (\(count))" : ""
        switch self {
        case .archive: return "Archive\(suffix)"
        case .unarchive: return "Unarchive\(suffix)"
        }
    }

    /// The past-tense confirmation a toast would use.
    ///
    /// It counts even at ONE, unlike ``title`` — and for the reason the
    /// favorites toast does. A press over a mixed selection of three changes
    /// only the rows that were not already there, so "Archived." would let the
    /// user read it as all three. "Archived 1 item." is the only wording that
    /// describes what actually happened, and the count is exactly what makes the
    /// undo's scope legible.
    var completedMessage: String {
        let n = count
        let items = "\(n) item\(n == 1 ? "" : "s")"
        switch self {
        case .archive: return "Archived \(items)"
        case .unarchive: return "Unarchived \(items)"
        }
    }
}

/// Decide the archive verb for `targets`, given which of them are currently
/// archived (023 · A3).
///
/// - An EMPTY selection has no verb — `nil`, so a menu omits the item rather
///   than offering a no-op, and a key press falls through instead of being
///   swallowed.
/// - EVERY target archived → ``ShelfVerb/unarchive(count:)``. This is the shelf,
///   and it is also the detail page opened from the shelf.
/// - Anything else → ``ShelfVerb/archive(count:)``. That covers the ordinary
///   case (nothing archived) and the MIXED one, which converges to "all
///   archived" rather than flipping — see the file header.
///
/// `archived` may name ids outside `targets` (a caller holding a wider set of
/// known-archived ids); only the intersection counts. Duplicates in `targets`
/// are collapsed, so a widened post that names an asset twice does not inflate
/// the count a menu shows.
///
/// **Unsorted is not special here, deliberately.** Archiving an item that lives
/// in the protected Unsorted folder is allowed: archive changes no membership,
/// so the F3 invariant ("an asset with no other membership is in Unsorted")
/// still holds afterwards — the asset is in Unsorted, archived. Triaging the
/// to-do pile with "not now" is arguably the verb's best use, and a special case
/// here would take it away for a rule that is not actually at risk.
nonisolated func shelfVerb(targets: [UUID], archived: Set<UUID>) -> ShelfVerb? {
    let distinct = Set(targets)
    guard !distinct.isEmpty else { return nil }
    return distinct.isSubset(of: archived)
        ? .unarchive(count: distinct.count)
        : .archive(count: distinct.count)
}
