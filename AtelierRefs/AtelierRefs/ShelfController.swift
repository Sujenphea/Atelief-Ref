//
//  ShelfController.swift
//  AtelierRefs
//
//  023 · A2 — the app-side owner of the Archived destination: load the shelf,
//  take things off it, and publish enough state for the pane to be honest about
//  what it is showing.
//
//  Shaped after `DuplicateReviewController` (012 · I5), which was shaped after
//  `LibraryStatsController` (016 · A): the state is `@MainActor`, the services
//  arrive per call rather than being held, and the controller owns nothing but
//  that state. A fourth shape for "a pane with a list and a verb" would be a
//  fourth set of bugs.
//
//  It lives here rather than inside `IngestionModel` for the reason 023 gives
//  explicitly: that file is already the largest in the repo at ~3,600 lines, and
//  the shelf shares nothing with it — no selected folder, no drag routing, no
//  reorder, no undo stack of its own.
//
//  What it deliberately is NOT:
//
//   • **It is not a collection.** There is no add, no move, no reorder, no cover.
//     An archive you can reorganise is just another collection with extra steps,
//     and every one of those verbs would need a membership the shelf does not
//     have.
//   • **It never purges.** Nothing here deletes on a timer, a count or an age.
//     Deleting from the shelf is the ordinary recoverable delete the grid
//     already owns (`IngestionModel.requestDelete`), reached the same way, with
//     the same undo.
//   • **It caches nothing across a change.** Every mutation reloads from the
//     database rather than patching the published array — the same
//     authoritative-reload rule `DuplicateReviewController` follows, and for the
//     same reason: this surface changes underneath itself (a delete, a ⌘Z, a
//     capture landing) and a patched list would offer verbs on rows that are
//     already gone.
//

import AtelierCore
import Combine
import Foundation
import os

@MainActor
final class ShelfController: ObservableObject {

    /// The shelf, most recently archived first — exactly what
    /// ``AppServices/shelfAssets()`` returns, in its order. Empty until
    /// ``load(services:)`` runs, which is indistinguishable from "nothing is
    /// archived"; ``hasLoaded`` is what tells the pane which of those it is
    /// looking at, so the empty state cannot say "Nothing archived" about a shelf
    /// it has not read yet.
    @Published private(set) var items: [AssetDetail] = []

    /// Bumped on every successful load. The grid host keys its layout cache on an
    /// integer rather than diffing the array, and unarchiving one of five rows
    /// leaves a list that is a different length but could otherwise compare equal
    /// element-wise to a stale solve.
    @Published private(set) var itemsVersion = 0

    /// Whether a load is in flight.
    @Published private(set) var isLoading = false

    /// Whether the shelf has been read at least once this session.
    @Published private(set) var hasLoaded = false

    /// Why the last load or unarchive failed, in words; `nil` when all is well.
    /// Published rather than logged-and-swallowed: an empty pane with no
    /// explanation is the failure mode that reads as data loss.
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "com.atelier.refs", category: "shelf")

    /// How the shelf is actually read. Overridable, exactly as
    /// ``LibrarySearchModel/runQuery`` is and for the same reason: the states
    /// this controller exists to keep straight — unread vs empty vs failed, and
    /// which of two overlapping reads wins — cannot be provoked through a real
    /// database on demand. A test that could not make a read fail would leave
    /// the branch that matters most (the pane must NOT blank) unasserted.
    ///
    /// The default is the live call, so every production path goes through
    /// `AppServices` unchanged.
    var readShelf: (AppServices) async throws -> [AssetDetail] = {
        try await $0.shelfAssets()
    }

    /// How many items are on the shelf — the pane's subtitle, and the number the
    /// sidebar badge would use.
    var count: Int { items.count }

    /// True only when the shelf has been READ and is genuinely empty.
    var isEmpty: Bool { hasLoaded && items.isEmpty }

    // MARK: - Reading

    /// Issue counter for in-flight loads. The pane reloads on appear, on a
    /// navigation pulse and after every verb, so overlapping reads are normal —
    /// and `await` means they can finish in an order other than the one they
    /// were issued in. A ticket makes the NEWEST read win rather than the
    /// last-arriving one, which is not the same thing and is the difference
    /// between the pane settling on current state and settling on stale state.
    private var loadSeq = 0

    /// Re-read the shelf from the database, authoritatively.
    func load(services: AppServices) async {
        loadSeq &+= 1
        let ticket = loadSeq
        isLoading = true
        do {
            let fetched = try await readShelf(services)
            // A newer load was issued while this one was in flight — its answer
            // is the one that should land, so drop this result silently rather
            // than overwriting the fresher read with an older one.
            guard ticket == loadSeq else { return }
            items = fetched
            itemsVersion &+= 1
            hasLoaded = true
            lastError = nil
        } catch {
            guard ticket == loadSeq else { return }
            // The previous `items` are LEFT in place. A failed refresh means "I
            // could not check", not "the shelf is empty", and blanking the pane
            // would say the second.
            lastError = error.localizedDescription
            log.error("shelf load failed: \(error.localizedDescription, privacy: .public)")
        }
        // Only the newest load owns the spinner; a superseded one leaves it up
        // for the read that is still running.
        if ticket == loadSeq { isLoading = false }
    }

    // MARK: - The verb

    /// Take `assetIDs` off the shelf and reload.
    ///
    /// Returns the number of rows that actually changed, which is what a caller
    /// registering an undo needs — unarchiving something already unarchived is a
    /// no-op and must not push an undo entry that would re-archive it.
    ///
    /// The reload is unconditional, even on a zero-row result: if this call
    /// changed nothing because someone else already unarchived those rows, the
    /// published list is precisely the thing that is now stale.
    @discardableResult
    func unarchive(_ assetIDs: [UUID], services: AppServices) async -> Int {
        guard !assetIDs.isEmpty else { return 0 }
        var changed = 0
        do {
            changed = try await services.unarchive(assetIDs)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("unarchive failed: \(error.localizedDescription, privacy: .public)")
        }
        await load(services: services)
        return changed
    }

    /// Put `assetIDs` back on the shelf and reload — the inverse of
    /// ``unarchive(_:services:)``, so an undo of an unarchive has a verb to call
    /// that keeps this pane's state true. Returns the rows that changed.
    @discardableResult
    func archive(_ assetIDs: [UUID], services: AppServices) async -> Int {
        guard !assetIDs.isEmpty else { return 0 }
        var changed = 0
        do {
            changed = try await services.archive(assetIDs)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("archive failed: \(error.localizedDescription, privacy: .public)")
        }
        await load(services: services)
        return changed
    }
}
