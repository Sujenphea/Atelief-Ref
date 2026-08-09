//
//  DetailStepTests.swift
//  AtelierRefsTests
//
//  026 · I3 — **step, don't dismiss**, pinned as pure functions in the shape
//  `DeleteIntentTests` pins `deleteIntent`: runs in, a decision out, no view, no
//  model, no database.
//
//  026's test strategy is explicit that this is where the off-by-one lives and that
//  it "should not be tested through the view", so the two decisions are separated:
//  ``DetailStep/next(oldRun:oldIndex:newRun:)`` answers *which item takes the place*
//  (the `min` clamp, and specifically the last-item case where the clamp IS the
//  behaviour rather than a guard), and
//  ``DetailStep/outcome(shownID:intent:newRun:runCollectionID:)`` answers *whether a
//  reload is a step at all* — the explicit-intent gate that keeps a collection switch
//  from leaving the page open on a stranger.
//
//  The second suite pins the seam the gate depends on: which verbs arm the intent.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Detail page: step, don't dismiss (026 I3)")
struct DetailStepTests {

    /// A stable, ordered run of distinct ids. Deterministic so a failure names a
    /// position rather than a random UUID.
    private static func run(_ count: Int) -> [UUID] {
        (0..<count).map { i in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!
        }
    }

    /// A run that shares no ids with ``run(_:)`` — a DIFFERENT collection's feed.
    private static func otherRun(_ count: Int) -> [UUID] {
        (0..<count).map { i in
            UUID(uuidString: String(format: "ffffffff-0000-0000-0000-%012d", i))!
        }
    }

    /// `run(n)` with the element at `index` removed — what a delete leaves behind.
    private static func dropping(_ index: Int, from ids: [UUID]) -> [UUID] {
        var copy = ids
        copy.remove(at: index)
        return copy
    }

    // MARK: - Which item takes the place

    /// The ordinary triage press: judge, delete, and the NEXT item is on screen.
    @Test("a middle item steps to the one that slid into its slot")
    func middleStepsForward() {
        let old = Self.run(5)
        let new = Self.dropping(2, from: old)
        #expect(DetailStep.next(oldRun: old, oldIndex: 2, newRun: new) == old[3])
    }

    /// Position 0 is not special — the item that took slot 0 is still "next".
    @Test("the first item steps to the new first item")
    func firstStepsForward() {
        let old = Self.run(4)
        let new = Self.dropping(0, from: old)
        #expect(DetailStep.next(oldRun: old, oldIndex: 0, newRun: new) == old[1])
    }

    /// **The clamp.** There is no next item at the end of the run, and
    /// `min(oldIndex, count - 1)` yields the one BEFORE it — which is the decision,
    /// not a defensive bound. Drop the `min` and this reads past the end.
    @Test("the last item steps BACK to its predecessor")
    func lastStepsBack() {
        let old = Self.run(4)
        let new = Self.dropping(3, from: old)
        #expect(DetailStep.next(oldRun: old, oldIndex: 3, newRun: new) == old[2])
        // Independently of length: a run of two, deleting the second, lands on the
        // first — the smallest case where forward and backward differ.
        let pair = Self.run(2)
        #expect(
            DetailStep.next(oldRun: pair, oldIndex: 1, newRun: Self.dropping(1, from: pair))
                == pair[0])
    }

    /// Deleting the only item leaves nowhere to go — the caller closes the page.
    @Test("a run of one steps nowhere")
    func runOfOne() {
        let old = Self.run(1)
        #expect(DetailStep.next(oldRun: old, oldIndex: 0, newRun: []) == nil)
    }

    /// The same answer when a multi-item run is emptied at once (a multi-select
    /// delete from behind the page, an undo that cleared the folder).
    @Test("an emptied run steps nowhere")
    func emptiedRun() {
        let old = Self.run(6)
        #expect(DetailStep.next(oldRun: old, oldIndex: 3, newRun: []) == nil)
    }

    /// **Not a delete.** The reload kept the item, so there is nothing to step to —
    /// this is the guard that keeps an ordinary reorder or a favourite toggle from
    /// moving the page.
    @Test("an item still present in the new run does not step")
    func stillPresentDoesNotStep() {
        let old = Self.run(5)
        // Reordered, not shortened: every id survives.
        let new = Array(old.reversed())
        #expect(DetailStep.next(oldRun: old, oldIndex: 2, newRun: new) == nil)
        #expect(DetailStep.next(oldRun: old, oldIndex: 2, newRun: old) == nil)
    }

    /// A stale intent whose index no longer addresses the run it was captured
    /// against cannot name a departed item, so it names nothing.
    @Test("an out-of-range index steps nowhere")
    func outOfRangeIndex() {
        let old = Self.run(3)
        #expect(DetailStep.next(oldRun: old, oldIndex: 3, newRun: Self.run(2)) == nil)
        #expect(DetailStep.next(oldRun: old, oldIndex: -1, newRun: Self.run(2)) == nil)
        #expect(DetailStep.next(oldRun: [], oldIndex: 0, newRun: Self.run(2)) == nil)
    }

    /// Several items left at once (a multi-select delete behind the page). The slot
    /// is still the right question to ask: whatever now occupies it is what the user
    /// should be looking at, and the clamp handles a run that shrank past the index.
    @Test("a shrink past the old index clamps to the new last item")
    func shrinkPastIndexClamps() {
        let old = Self.run(6)
        let new = [old[0], old[1]]          // 2,3,4,5 all left
        #expect(DetailStep.next(oldRun: old, oldIndex: 4, newRun: new) == old[1])
    }

    // MARK: - The gate: is this reload a step at all?

    /// The folder every fixture run belongs to, unless a test says otherwise.
    private static let folder = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    private static let otherFolder = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!

    private static func intent(
        _ ids: [UUID], _ index: Int, in collectionID: UUID = DetailStepTests.folder
    ) -> DetailStepIntent {
        DetailStepIntent(
            itemID: ids[index], index: index, run: ids, collectionID: collectionID)
    }

    /// `DetailStep.outcome` with the fixture folder on both sides.
    private static func outcome(
        shown: UUID?, intent: DetailStepIntent?, newRun: [UUID],
        runCollectionID: UUID? = DetailStepTests.folder
    ) -> DetailReloadOutcome {
        DetailStep.outcome(
            shownID: shown, intent: intent, newRun: newRun, runCollectionID: runCollectionID)
    }

    /// The armed case: the page's own ⌫ / ⌘⌫ took the shown item out, so the page
    /// moves on instead of closing.
    @Test("intent set + id gone → step")
    func intentSetAndGoneSteps() {
        let old = Self.run(5)
        let new = Self.dropping(1, from: old)
        #expect(Self.outcome(shown: old[1], intent: Self.intent(old, 1), newRun: new)
            == .step(old[2]))
    }

    /// **Why the gate exists.** The same departure with no intent behind it is a move
    /// out of the collection, a reorder that dropped the item, or a collection switch
    /// — and every one of those still closes the page, exactly as before 026. This is
    /// the assertion that inference was rejected in favour of an explicit flag.
    @Test("intent clear + id gone → close (the pre-026 behaviour, unchanged)")
    func noIntentAndGoneCloses() {
        let old = Self.run(5)
        let new = Self.dropping(1, from: old)
        #expect(Self.outcome(shown: old[1], intent: nil, newRun: new) == .close)
        // A collection switch: an entirely different feed, sharing no ids. Inferring
        // "the id is gone, so step" would leave the page open on a stranger from a
        // folder the user just navigated away from.
        #expect(
            Self.outcome(
                shown: old[1], intent: nil, newRun: Self.otherRun(3),
                runCollectionID: Self.otherFolder) == .close)
    }

    /// **The race the folder stamp is for.** ⌫ is pressed, and before its reload
    /// lands the user switches collections — so the intent IS armed, the shown id IS
    /// gone, and the new run is full of items at every index. Without the folder
    /// check this steps to `otherRun[1]`, a picture from a folder the user is no
    /// longer looking at. With it, the page closes.
    @Test("an armed intent cannot step into a DIFFERENT collection's reload")
    func armedIntentCannotCrossACollectionSwitch() {
        let old = Self.run(5)
        let switched = Self.otherRun(4)
        #expect(
            Self.outcome(
                shown: old[1], intent: Self.intent(old, 1), newRun: switched,
                runCollectionID: Self.otherFolder) == .close)
        // Same shape, same folder — the step this would otherwise have produced, so
        // the assertion above is about the folder and nothing else.
        #expect(
            Self.outcome(
                shown: old[1], intent: Self.intent(old, 1, in: Self.otherFolder),
                newRun: switched, runCollectionID: Self.otherFolder) == .step(switched[1]))
    }

    /// An intent that named an item which then DIDN'T leave (a remove that no-opped,
    /// an undo that raced the reload) must not move the page — and the flag is spent
    /// regardless, because the caller consumed it to ask this question at all.
    @Test("intent set but id still present → no step")
    func intentSetButPresentStays() {
        let old = Self.run(5)
        #expect(Self.outcome(shown: old[1], intent: Self.intent(old, 1), newRun: old) == .stay)
    }

    /// An intent armed against a DIFFERENT item than the one on screen — the user
    /// arrowed away between the verb and its reload. Not this page's step.
    @Test("an intent naming another item does not step this one")
    func mismatchedIntentCloses() {
        let old = Self.run(5)
        let new = Self.dropping(1, from: old)
        #expect(Self.outcome(shown: old[1], intent: Self.intent(old, 3), newRun: new) == .close)
    }

    /// Deleting the only item: armed, gone, and nothing left — the one case that
    /// still closes the page.
    @Test("intent set + run emptied → close")
    func emptiedRunCloses() {
        let old = Self.run(1)
        #expect(Self.outcome(shown: old[0], intent: Self.intent(old, 0), newRun: []) == .close)
    }

    /// No page up: reloads are none of this decision's business, armed or not.
    @Test("nothing shown → stay")
    func nothingShownStays() {
        let old = Self.run(3)
        #expect(Self.outcome(shown: nil, intent: nil, newRun: old) == .stay)
        #expect(Self.outcome(shown: nil, intent: Self.intent(old, 0), newRun: old) == .stay)
    }

    /// The triage loop itself: five presses in a row, each one landing on the item
    /// that took the last one's place, with the page never closing. This is the
    /// behaviour 026 I3 is FOR, expressed over the pure functions.
    @Test("five deletes in a row keep stepping forward and never close")
    func fiveInARow() {
        var run = Self.run(8)
        var shown = run[2]
        for _ in 0..<5 {
            let index = run.firstIndex(of: shown)!
            let intent = DetailStepIntent(
                itemID: shown, index: index, run: run, collectionID: Self.folder)
            let newRun = Self.dropping(index, from: run)
            let outcome = Self.outcome(shown: shown, intent: intent, newRun: newRun)
            guard case .step(let next) = outcome else {
                Issue.record("press landed on \(outcome), not a step")
                return
            }
            // Always the item that was immediately after the one just judged.
            #expect(next == run[index + 1])
            run = newRun
            shown = next
        }
        #expect(run.count == 3)
    }
}

// MARK: - The arming seam

/// The gate is only worth anything if exactly the right verbs arm it, so this pins
/// the model side: the detail page's ⌫ / ⌘⌫ arm an intent carrying **pre-reload**
/// state, nothing else does, and the flag is genuinely one-shot.
///
/// State is asserted against the model in the shape `TwoTierDeleteTests` established;
/// the run is captured synchronously by the verb, so these read it before the
/// asynchronous reload it triggers has landed.
@MainActor
@Suite("Detail step intent: armed by the page's verbs only (026 I3)")
struct DetailStepIntentWiringTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        try await CarouselRig.makeModel("detail-step-intent")
    }

    /// Open `collectionID` the way navigating to it does — `selectedFolderID` is what
    /// the remove verb reads for "where you are looking".
    private func open(_ model: IngestionModel, _ collectionID: UUID) async throws {
        await model.refreshFolders()
        model.selectedFolderID = collectionID
        try await CarouselRig.load(model, collectionID)
    }

    /// Wait for a verb's write AND the reload it triggers. `waitForWrites()` only
    /// drains the write queue; the `loadContents` that queue kicks off publishes
    /// later, so a test reading `detailRun` straight after it sees the OLD run.
    private func waitForDeparture(_ model: IngestionModel, of itemID: UUID) async throws {
        await model.waitForWrites()
        for _ in 0..<200 where model.detailRun.contains(where: { $0.item.id == itemID }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A folder holding three ordered, media-less items.
    private func seededFolder(
        _ model: IngestionModel, _ services: AppServices, named: String = "Refs"
    ) async throws -> (id: UUID, assetIDs: [UUID]) {
        let folder = try await services.createCollection(name: named)
        let ids = try await CarouselRig.seedPost(
            url: nil, count: 3, into: folder.id, services, hexSeed: 0)
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        try await open(model, folder.id)
        return (folder.id, ids)
    }

    /// ⌫ from the page captures the run AS IT IS, with the departing item's position
    /// in it — the whole reason the intent is state and not a boolean.
    @Test("the page's ⌫ arms an intent carrying the PRE-reload run and index")
    func removeArmsPreReloadState() async throws {
        let (model, services) = try await makeModel()
        let folder = try await seededFolder(model, services)
        let shown = model.detailRun[1]
        let runBefore = model.detailRun.map { $0.item.id }

        model.removeFromCurrentFolder(itemID: shown.item.id, assetIDs: [shown.asset.id])

        let intent = try #require(model.consumeDetailStepIntent())
        #expect(intent.itemID == shown.item.id)
        #expect(intent.index == 1)
        #expect(intent.run == runBefore)
        #expect(intent.collectionID == folder.id)
        // And it names the item that will take the departing one's place.
        try await waitForDeparture(model, of: shown.item.id)
        #expect(
            DetailStep.next(
                oldRun: intent.run, oldIndex: intent.index,
                newRun: model.detailRun.map { $0.item.id }) == runBefore[2])
    }

    /// ⌘⌫ arms at REQUEST time, not confirm time — the run must be captured before
    /// the dialog's outcome, because by then the reload has already replaced it.
    @Test("the page's ⌘⌫ arms when the confirmation is staged")
    func requestDeleteArms() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        let shown = model.detailRun[0]

        model.requestDelete(itemID: shown.item.id, assetIDs: [shown.asset.id])
        #expect(model.pendingDeletion != nil)
        #expect(model.consumeDetailStepIntent()?.itemID == shown.item.id)
    }

    /// Consumed on read. A verb whose reload never arrives leaves nothing behind for
    /// a later, unrelated reload to act on.
    @Test("the intent is one-shot — a second read is empty")
    func consumeIsOneShot() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        let shown = model.detailRun[0]

        model.requestDelete(itemID: shown.item.id, assetIDs: [shown.asset.id])
        #expect(model.consumeDetailStepIntent() != nil)
        #expect(model.consumeDetailStepIntent() == nil)
    }

    /// Escape / Cancel on the confirmation. Every dismissal route lands on
    /// `cancelPendingDeletion`, so the intent dies with the dialog rather than
    /// waiting for some later reload to fire it.
    @Test("cancelling the ⌘⌫ dialog disarms the step")
    func cancelDisarms() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        let shown = model.detailRun[0]

        model.requestDelete(itemID: shown.item.id, assetIDs: [shown.asset.id])
        model.cancelPendingDeletion()
        #expect(model.consumeDetailStepIntent() == nil)
    }

    /// **In Unsorted, ⌫ only explains itself** (022 · D2) — no removal, so no reload,
    /// so an intent armed here would sit until an unrelated later reload consumed it
    /// and stepped the page somewhere the user never asked to go.
    @Test("⌫ in Unsorted arms nothing")
    func unsortedArmsNothing() async throws {
        let (model, services) = try await makeModel()
        _ = try await CarouselRig.seedPost(
            url: nil, count: 3, into: Collection.unsortedID, services, hexSeed: 0)
        try await open(model, Collection.unsortedID)
        let shown = model.detailRun[0]

        model.removeFromCurrentFolder(itemID: shown.item.id, assetIDs: [shown.asset.id])
        #expect(model.consumeDetailStepIntent() == nil)
        // Still there — the verb declined, it did not fail silently.
        await model.waitForWrites()
        #expect(model.items.count == 3)
    }

    /// The grid's own ⌫ / ⌘⌫ are NOT the page's. They arm nothing, so a delete made
    /// behind a page that is later opened cannot leave a step waiting.
    @Test("the grid's verbs arm nothing")
    func gridVerbsArmNothing() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        _ = model.selectionStore.apply(.selectOnly(model.displayItems[0].item.id))

        model.removeSelectedFromFolder()
        #expect(model.consumeDetailStepIntent() == nil)
        await model.waitForWrites()

        model.requestDeleteSelected()
        #expect(model.consumeDetailStepIntent() == nil)
        model.cancelPendingDeletion()
    }

    /// **The page's verbs target the item ON SCREEN, never the grid's cursor** (354).
    ///
    /// Stepping with ← / → writes nothing to the model on purpose (that is what keeps
    /// the grid from re-rendering per step), so the lead stays parked on the item the
    /// page was OPENED on however far the user pages. A verb that reads the lead is
    /// therefore not a near-miss on this page — it acts on a different picture, and for
    /// ⌘⌫ that is a destroyed picture the user was not looking at. This pins the two
    /// answers apart at the seam the Edit menu and the overflow menu both call.
    @Test("the page's ⌘⌫ destroys the shown item, not the lead the grid parked on")
    func pageDeleteTargetsShownItemNotLead() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        // Opened on the first item — the lead the grid keeps — then paged to the third.
        let opened = model.detailRun[0]
        _ = model.selectionStore.apply(.setLead(opened.item.id))
        let shown = model.detailRun[2]
        #expect(model.leadItem?.item.id == opened.item.id)

        model.requestDelete(itemID: shown.item.id, assetIDs: [shown.asset.id])

        #expect(model.pendingDeletion?.assetIDs == [shown.asset.id])
        #expect(model.pendingDeletion?.assetIDs.contains(opened.asset.id) == false)
        #expect(model.consumeDetailStepIntent()?.itemID == shown.item.id)
        model.cancelPendingDeletion()
    }

    /// The same, for ⌫: the removal leaves the SHOWN item's asset, and the lead's
    /// survives — the verb the softest key on the keyboard is bound to.
    @Test("the page's ⌫ removes the shown item, not the lead")
    func pageRemoveTargetsShownItemNotLead() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        let opened = model.detailRun[0]
        _ = model.selectionStore.apply(.setLead(opened.item.id))
        let shown = model.detailRun[2]

        model.removeFromCurrentFolder(itemID: shown.item.id, assetIDs: [shown.asset.id])
        try await waitForDeparture(model, of: shown.item.id)

        #expect(!model.detailRun.contains { $0.item.id == shown.item.id })
        #expect(model.detailRun.contains { $0.item.id == opened.item.id })
    }

    /// **Confirming is not cancelling** (354). SwiftUI writes `false` into the dialog's
    /// `isPresented` binding when it dismisses — including on the way out of the Delete
    /// button — so `ContentView`'s binding calls `cancelPendingDeletion()` on the
    /// CONFIRM path too, a moment after the confirm cleared the pending state and well
    /// before the delete's asynchronous reload lands. That disarmed the intent the
    /// press had just armed, and the page closed instead of stepping. Here in the exact
    /// order the app produces it.
    @Test("the dialog's dismissal write after Delete does not disarm the step")
    func confirmThenDismissalWriteKeepsIntent() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        let shown = model.detailRun[1]

        model.requestDelete(itemID: shown.item.id, assetIDs: [shown.asset.id])
        model.confirmPendingDeletion()      // the button's action
        model.cancelPendingDeletion()       // the binding's `false`, right behind it

        // Still armed for the reload the delete is about to cause.
        let intent = try #require(model.consumeDetailStepIntent())
        #expect(intent.itemID == shown.item.id)
        #expect(intent.index == 1)
        try await waitForDeparture(model, of: shown.item.id)
    }

    /// And the guard that makes that work does not cost Cancel its disarm: a dialog the
    /// user calls off still arrives with the deletion staged, so it still clears.
    @Test("cancelling with a deletion staged still disarms")
    func cancelWithPendingStillDisarms() async throws {
        let (model, services) = try await makeModel()
        _ = try await seededFolder(model, services)
        let shown = model.detailRun[0]

        model.requestDelete(itemID: shown.item.id, assetIDs: [shown.asset.id])
        #expect(model.pendingDeletion != nil)
        model.cancelPendingDeletion()
        #expect(model.pendingDeletion == nil)
        #expect(model.consumeDetailStepIntent() == nil)
    }

    /// ⌫ on an item whose ONLY membership is this collection re-homes it to Unsorted
    /// (the F3 invariant in `AppServices.removeAssets`). It still leaves THIS feed, so
    /// the page steps — the behaviour reads as "filed away", not as a failed delete.
    @Test("a re-home to Unsorted still leaves this feed, so it still steps")
    func rehomeToUnsortedStillSteps() async throws {
        let (model, services) = try await makeModel()
        let folder = try await seededFolder(model, services)
        let shown = model.detailRun[1]
        let runBefore = model.detailRun.map { $0.item.id }

        model.removeFromCurrentFolder(itemID: shown.item.id, assetIDs: [shown.asset.id])
        let intent = try #require(model.consumeDetailStepIntent())
        try await waitForDeparture(model, of: shown.item.id)

        // Gone from here, alive in Unsorted.
        #expect(!model.detailRun.contains { $0.item.id == shown.item.id })
        let unsorted = try await services.collectionItems(in: Collection.unsortedID)
        #expect(unsorted.contains { $0.asset.id == shown.asset.id })
        // And the page has somewhere to go.
        #expect(
            DetailStep.outcome(
                shownID: shown.item.id, intent: intent,
                newRun: model.detailRun.map { $0.item.id },
                runCollectionID: model.loadedCollectionID) == .step(runBefore[2]))
        #expect(model.loadedCollectionID == folder.id)
    }
}
