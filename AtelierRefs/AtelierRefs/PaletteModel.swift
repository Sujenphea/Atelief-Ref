//
//  PaletteModel.swift
//  AtelierRefs
//
//  099 · P6 — **the floating reference palette's brain**, and the answer to
//  [011](../../.docs/feature-todo/011-ux-features.md) · Cluster D as the user wrote
//  it: *read-only + drag-out, one window, a picker.*
//
//  The backlog line this closes said "the app still declares one window group",
//  and it did: `AtelierRefsApp` had exactly one `WindowGroup` and the standard
//  `Settings` scene, and nothing else. The palette is the app's second real window
//  and its first `Window` (singular) scene — which is what makes 011's "one window,
//  one focus" a property of the scene graph rather than a rule someone has to
//  enforce: `openWindow(id:)` on a `Window` raises the one that exists.
//
//  ## What it shows, and what it refuses to
//
//  A collection or a saved search — both of which the app already knows how to read
//  through ``CollectionFeed``, so the palette owns a second ``CollectionReadModel``
//  and not one line of new fetching (099 · 1A's whole point, demonstrated for the
//  third time after P3's main window and P4's smart collections).
//
//  **A Space is not in v1**, and ``PaletteDestinations/canShow(_:)`` is where that
//  is stated so the day someone adds a `SidebarItem` case they have to answer for
//  it. The reason is not effort: the canvas host is an EDITING model end to end —
//  `SpaceModel` owns placements, a selection, an undo stack and a drag router that
//  writes tile positions — so "a board, read-only" is not a configuration of it but
//  a second renderer. `MasonryGridHost` already had a read-only shape available for
//  the price of three flags (``GridInteraction``); `CanvasHostView` does not.
//
//  ## The picker is P5's search, not a second one
//
//  ⌘K and the palette ask the same question — *which destination?* — so they share
//  ``SwitcherRanking`` (the three tiers, the recents key, the shared ordering) and
//  ``SwitcherModel`` (the query, the results, the cursor). The palette adds exactly
//  one thing on top: a filter, because it can show fewer kinds of destination than
//  ⌘K can go to. That filter is the only palette-specific line in the whole search,
//  and it is a `switch` with no `default`.
//

import AtelierCore
import Combine
import Foundation

// MARK: - Which destinations a palette can show

/// The palette's scope over the app's destinations (011 · Cluster D).
nonisolated enum PaletteDestinations {

    /// Whether the reference palette can show this destination.
    ///
    /// A `switch` with **no `default`**, the discipline
    /// ``SidebarItem/acceptsAssetDrops`` and ``SwitcherRecents/token(for:)``
    /// established for this enum: a new destination has to decide whether the
    /// palette can show it rather than inheriting an answer.
    ///
    /// Only the two READ-ONLY-able feeds qualify. Home, Capture and Archived are
    /// whole screens rather than feeds (Home is a gallery of cards, Capture is a
    /// settings surface); Archived could qualify one day but is a triage surface
    /// whose only verb is unarchive, which is precisely what a read-only palette
    /// cannot offer. A Space is refused for the reason in this file's header.
    static func canShow(_ destination: SidebarItem) -> Bool {
        switch destination {
        case .collection: true
        case .savedSearch: true
        case .home: false
        case .capture: false
        case .shelf: false
        case .space: false
        #if DEBUG
        case .theme: false
        #endif
        }
    }

    /// The palette picker's candidates: ``SwitcherRanking/candidates(folders:unsortedID:spaces:savedSearches:)``
    /// — the sidebar's own top-to-bottom order — narrowed to what a palette can show.
    ///
    /// **The spaces are passed in and then filtered out, deliberately.** Handing
    /// `[]` would make the exclusion invisible: the list would simply not contain
    /// spaces and no test could tell that from a bug. Built and dropped, the rule is
    /// ``canShow(_:)``'s and one test (`aSpaceIsASwitcherCandidateAndNotAPaletteOne`)
    /// asserts the two surfaces differ in exactly that way.
    static func candidates(
        folders: [Collection],
        unsortedID: UUID,
        spaces: [Space],
        savedSearches: [SavedSearch]
    ) -> [SwitcherCandidate] {
        SwitcherRanking.candidates(
            folders: folders, unsortedID: unsortedID,
            spaces: spaces, savedSearches: savedSearches
        ).filter { canShow($0.destination) }
    }

    /// The id inside a showable destination, or `nil` for one the palette refuses.
    /// The read model is keyed by `UUID` whichever feed it is on, so this is the one
    /// place the two cases collapse into one.
    static func feedID(of destination: SidebarItem) -> UUID? {
        switch destination {
        case .collection(let id): id
        case .savedSearch(let id): id
        default: nil
        }
    }
}

// MARK: - The model

/// The reference palette's state: what it shows, whether the picker is up, and the
/// per-library memory of the last answer.
///
/// **App-level, not window-level.** It is a `@StateObject` on `AtelierRefsApp`
/// beside `IngestionModel` and `GridViewPreferences`, for their reason: the palette
/// window and the main window are separate scenes, and a state object owned by
/// either would give the other its own copy — which would mean a sidebar row's
/// "Open in Palette" set a destination the palette window could not see.
@MainActor
final class PaletteModel: ObservableObject {

    /// The palette scene's id. One constant, read by the scene that declares it and
    /// by every `openWindow(id:)`, so a typo cannot open nothing silently.
    static let windowID = "palette"

    /// What the palette shows, or `nil` when it has never been pointed anywhere (a
    /// first launch, or a remembered destination that has since been deleted). The
    /// palette then opens on its picker rather than on an empty grid, because
    /// "choose something" is the honest state and "nothing here" is not.
    @Published private(set) var destination: SidebarItem?

    /// Bumped by ``show(_:)``. The shell watches it and raises the window; see
    /// ``show(_:)`` for why the raising is not done here.
    @Published private(set) var openPulse = 0

    /// Whether the destination picker is up over the grid.
    @Published var isPickingDestination = false

    /// The picker's query, results and cursor — **P5's model, unchanged** (099 · P6).
    /// One search over destinations, two surfaces.
    let picker = SwitcherModel()

    /// The library the memory belongs to; `nil` until it opens.
    private(set) var libraryID: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Per-library memory

    /// The per-library defaults key.
    ///
    /// `library.<id>.` per 016 §C item 3 — ``ClipboardWatcher/enabledKey(libraryID:)``'s
    /// shape and ``SwitcherRecents/defaultsKey(libraryID:)``'s, which is the point of
    /// the discipline: multi-library needs no migration later because every new
    /// preference adopts the prefix now. This is the fourth to do so.
    nonisolated static func defaultsKey(libraryID: String) -> String {
        "library.\(libraryID).paletteDestination"
    }

    /// Bind to an open library and restore what the palette last showed there.
    ///
    /// The stored value is a ``SwitcherRecents`` TOKEN — the same spelling ⌘K's MRU
    /// persists — rather than a second encoding of a destination. Two files writing
    /// `collection:<uuid>` in two ways is how a rename of one silently orphans the
    /// other; sharing the pair means a change has to be made in one place.
    ///
    /// A token that no longer parses, or that names a destination the palette cannot
    /// show (a `space:` row hand-written into the plist, or one persisted by a future
    /// version), is dropped silently. The palette opens on its picker, which is where
    /// it would have opened anyway.
    func activate(libraryID: String) {
        self.libraryID = libraryID
        guard
            let token = defaults.string(forKey: Self.defaultsKey(libraryID: libraryID)),
            let restored = SwitcherRecents.destination(forToken: token),
            PaletteDestinations.canShow(restored)
        else { return }
        destination = restored
    }

    /// Point the palette at a destination **and ask for the window**.
    ///
    /// The raising is a `@Published` pulse rather than a call, because
    /// `openWindow(id:)` is a SwiftUI environment action and this object is not a
    /// view. The shell observes the pulse; see `AppShellView`. A counter rather than
    /// a flag so two "Open in Palette" clicks on the same row both raise it — a
    /// boolean would have to be reset by whoever consumed it, and a consumer that
    /// forgot would make the SECOND click do nothing.
    func show(_ destination: SidebarItem) {
        guard PaletteDestinations.canShow(destination) else { return }
        assign(destination)
        openPulse &+= 1
    }

    /// Point the palette at a destination it is ALREADY showing a window for — what
    /// the picker inside the palette commits. No pulse: the window is up, and asking
    /// for it again would order it forward over whatever the user is designing in,
    /// which is the one thing an always-on-top window must not do unasked.
    func choose(_ destination: SidebarItem) {
        guard PaletteDestinations.canShow(destination) else { return }
        assign(destination)
        isPickingDestination = false
    }

    /// Forget a destination that no longer exists.
    ///
    /// Called by the palette with the live lists. The `folders.isEmpty` guard is
    /// load-bearing: every library has an Unsorted row, so an empty list means the
    /// library has not published yet — and reconciling against it would drop the
    /// remembered destination on every launch, which is precisely the bug that makes
    /// "remembers what it last showed" untrue.
    func reconcile(folders: [Collection], savedSearches: [SavedSearch]) {
        guard !folders.isEmpty, let destination else { return }
        let survives: Bool
        switch destination {
        case .collection(let id): survives = folders.contains { $0.id == id }
        case .savedSearch(let id): survives = savedSearches.contains { $0.id == id }
        default: survives = false
        }
        guard !survives else { return }
        self.destination = nil
        isPickingDestination = true
        if let libraryID {
            defaults.removeObject(forKey: Self.defaultsKey(libraryID: libraryID))
        }
    }

    /// Assign and persist. A no-op write before the library id resolves,
    /// deliberately — ``SwitcherRecents/record(_:)``'s rule, and 016 §C's: writing to
    /// an un-namespaced key "for now" is exactly the migration the prefix avoids.
    private func assign(_ destination: SidebarItem) {
        self.destination = destination
        guard let libraryID, let token = SwitcherRecents.token(for: destination) else { return }
        defaults.set(token, forKey: Self.defaultsKey(libraryID: libraryID))
    }
}
