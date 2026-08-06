//
//  DetailStep.swift
//  AtelierRefs
//
//  026 · I3 — what the item detail page does when the item it is showing leaves the
//  feed: **step to whatever took its place, don't dismiss.**
//
//  The host used to close the page on any reload that dropped the shown id ("parity
//  with the old `leadItem == nil` gate"). That made the triage loop — open, judge,
//  delete, judge the next — cost a round trip through the grid per item, and it
//  landed the user wherever the grid's cursor happened to be rather than at the next
//  item in the run.
//
//  Two decisions are pinned here rather than in the view, because this is where the
//  off-by-one lives:
//
//    • **which item takes the place** of the departed one — `newRun[min(oldIndex,
//      count - 1)]`, i.e. "next" in every case except deleting the LAST item in the
//      run, where the same expression correctly yields "previous";
//    • **whether a reload is even a step at all** — gated on an explicit one-shot
//      ``DetailStepIntent`` the delete/remove verbs arm, never inferred from "the run
//      shrank and the id is gone". A move-out-of-collection, a reorder that drops the
//      item, and switching collections while the page is up all hit the same reload
//      path; inferring is how a collection switch leaves the page open showing a
//      stranger from a folder the user just navigated away from.
//
//  Pure and SwiftUI-free, in the shape `DeleteIntent` established, so the whole
//  matrix is pinned by tests without a window, a model, or a database.
//

import Foundation

/// The one-shot record that **the detail page** issued a verb which is about to take
/// the shown item out of the current feed (026 · I3).
///
/// Armed by ``IngestionModel/removeFromCurrentFolder(itemID:assetIDs:)`` and
/// ``IngestionModel/requestDelete(itemID:assetIDs:)`` — the page's ⌫ and ⌘⌫ — and
/// consumed by the host on the very next content reload. It carries **pre-reload**
/// state on purpose: by the time the reload arrives, `detailRun` has already been
/// replaced and the departed item's position is unrecoverable, so the position has to
/// be captured at the moment the verb is issued.
nonisolated struct DetailStepIntent: Equatable {
    /// The membership id the verb was issued against — the page's shown item. The
    /// host re-checks this against what is actually on screen, so arrowing away
    /// between the verb and its reload cancels the step instead of misdirecting it.
    let itemID: UUID
    /// `itemID`'s position in ``run`` when the verb was issued.
    let index: Int
    /// The detail run as it was BEFORE the verb's reload replaced it.
    let run: [UUID]
    /// The collection ``run`` was loaded from. Re-checked against the reloaded feed,
    /// so an intent can only ever step WITHIN the folder it was armed in: a delete
    /// that races a collection switch finds a different id here and closes, rather
    /// than presenting whatever happens to occupy that slot in a folder the user has
    /// just navigated to.
    let collectionID: UUID
}

/// What a content reload means for the detail page that is currently up (026 · I3).
nonisolated enum DetailReloadOutcome: Equatable {
    /// Nothing to do — no page is up, or the shown item survived the reload.
    case stay
    /// Show this item instead: it took the departed one's place in the run.
    case step(UUID)
    /// The shown item left and there is nothing to step to — drop the route.
    case close
}

/// The step-on-delete decision, as two pure functions (026 · I3).
nonisolated enum DetailStep {

    /// **The step, in one expression.** Where the page should go when the item at
    /// `oldIndex` of `oldRun` has left the feed that reloaded as `newRun` — or `nil`
    /// when it should not go anywhere.
    ///
    /// `newRun[min(oldIndex, newRun.count - 1)]` is the whole rule. The item that
    /// slid into the departed one's slot is "the next one" for every position in the
    /// run except the last, where there is no next and the clamp yields the item
    /// before it — which is the right answer, and the reason the clamp is not an
    /// off-by-one guard but the behaviour itself.
    ///
    /// `nil` in exactly three cases, each of which the caller reads as "do not step":
    ///  • `oldIndex` is not a position in `oldRun` (a stale or malformed intent);
    ///  • the item is STILL in `newRun` — the reload was not the departure this
    ///    intent was armed for, so the page stays where it is;
    ///  • `newRun` is empty — the collection has nothing left to show, and the page
    ///    closes rather than stepping to nothing.
    static func next(oldRun: [UUID], oldIndex: Int, newRun: [UUID]) -> UUID? {
        guard oldRun.indices.contains(oldIndex) else { return nil }
        let departed = oldRun[oldIndex]
        guard !newRun.contains(departed) else { return nil }
        guard !newRun.isEmpty else { return nil }
        return newRun[min(oldIndex, newRun.count - 1)]
    }

    /// **The gate.** What the host should do with a reload, given what is on screen,
    /// the intent it just consumed (`nil` when nothing armed one), and the new run.
    ///
    /// The ordering of the guards is the design:
    ///
    ///  1. Nothing on screen → ``DetailReloadOutcome/stay``. The page is not up.
    ///  2. The shown id survived → ``DetailReloadOutcome/stay``, *even with an intent
    ///     armed*. A remove that no-opped, an undo that raced the reload, or a
    ///     reload that simply is not the one the verb caused must not move the page;
    ///     the intent is spent either way (the caller consumed it to get here).
    ///  3. The shown id is gone, an intent names IT, and the reloaded feed is the
    ///     folder that intent was armed in → step, if there is somewhere to step to.
    ///  4. Anything else → ``DetailReloadOutcome/close``. That is the pre-026
    ///     behaviour, and it is deliberately what an UNGATED departure falls back to:
    ///     a move out of the collection, a reorder that dropped the item, or a
    ///     collection switch closes the page exactly as it always did.
    ///
    /// `runCollectionID` is the collection `newRun` was loaded from — the third
    /// condition. Without it, a ⌫ whose reload is overtaken by a collection switch
    /// would step to whatever sits at that index in the NEW folder, which is the one
    /// failure the explicit gate exists to prevent.
    static func outcome(
        shownID: UUID?, intent: DetailStepIntent?, newRun: [UUID], runCollectionID: UUID?
    ) -> DetailReloadOutcome {
        guard let shownID else { return .stay }
        guard !newRun.contains(shownID) else { return .stay }
        guard let intent, intent.itemID == shownID, intent.collectionID == runCollectionID,
              let nextID = next(oldRun: intent.run, oldIndex: intent.index, newRun: newRun)
        else { return .close }
        return .step(nextID)
    }
}
