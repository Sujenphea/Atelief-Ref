//
//  KeyMap.swift
//  AtelierRefs
//
//  024 · K1 — **the app's keyboard map, written down in one place.**
//
//  The app decides key presses in seven independent places: the Edit / File / View
//  menus (`AtelierRefsApp`), the collection grid (`gridKeyCommand`), the item detail
//  page (`detailStepDelta` + `DetailKeyCatcher`), the Space canvas (`toolShortcut` +
//  `CanvasHostView.keyDown`), the Space chrome's hoisted `keyboardShortcut` carriers
//  (`SpaceView`), the Home gallery (`CollectionsGalleryView`) and the sidebar outline
//  (`SidebarOutlineView.onKeyDown`). Until this file there was no list of what any of
//  them claimed, and nothing in the UI told a user that ~30 bindings existed at all.
//
//  **NOTHING DISPATCHES FROM HERE.** The pure decoders stay authoritative —
//  `gridKeyCommand`, `detailStepDelta`, `CanvasHostView.toolShortcut` and
//  `deleteIntent` are already tested, and rewriting dispatch to be table-driven would
//  be a large change for no user-visible gain. This table is a DESCRIPTION. It buys
//  three things, in order of value:
//
//   1. **A collision test** (`KeyMap.collisions(in:)`) — no two rows in the same
//      scope, or in `.global` plus any scope, may share a chord. This is the thing
//      that keeps a growing key map honest, and it is the main reason the table
//      exists.
//   2. **The shortcuts sheet** (`KeyboardShortcutsSheet`) renders straight from it.
//   3. **Menu titles** can read from it rather than restating a chord in prose.
//
//  A description can drift from what it describes, so every row that a pure decoder
//  owns names that decoder in ``Shortcut/decoder``, and `KeyMapContractTests` walks
//  each row back through it. A row whose decoder returns `nil` fails the build. Rows
//  delivered by a SwiftUI `keyboardShortcut` or an AppKit menu item carry
//  ``ShortcutDecoder/none`` — there is no pure function to ask, and inventing one
//  would be dispatch, which this file does not do.
//
//  ## Scope means "where the chord is live, and what it does there"
//
//  Not "which object registered it". A menu key equivalent is technically live
//  app-wide even when its item is disabled (File ▸ Export Moodboard… is ⌘⇧E on every
//  surface; it only DOES anything on a board), and a reference card that filed it
//  under "Everywhere" would be describing AppKit rather than the app. Two consequences
//  worth stating out loud, because the table cannot catch either:
//
//   • **⌘D means two things.** *Favorite* on a collection (Edit ▸ Favorite,
//     `AtelierRefsApp.swift:181`) and *Duplicate* on a board (`SpaceView.swift:816`).
//     Kept deliberately — the scope headings carry the distinction. Note that
//     Favorite's binding is a MENU key equivalent gated on `canToggleFavorite`, which
//     reads the collection grid's selection, so the isolation is by convention, not by
//     construction.
//   • **⌘Z / ⇧⌘Z are `.global`, but a Space overrides them** with the board's own undo
//     stack (`SpaceView.swift:702`). Same verb, different stack, so one row.
//
//  ## The constraint every bare-letter binding lives under
//
//  A bare letter must never fire while a text box has the keyboard. The three
//  surfaces that own one each solve it differently, and K3's `M` / `A` picked from
//  these rather than adding a fourth — the grid's pair rides `gridKeyCommand` inside
//  `keyDown`, the board's `A` rides `boardShortcut` inside the canvas host's:
//
//   • The canvas guards on `editingTileID` (`CanvasHostView.swift:1183`) before it
//     reads a key at all.
//   • The detail page's `DetailKeyCatcher` declines to steal first responder from an
//     `NSText` (`ItemDetailView.swift:1457`).
//   • The grid has no text entry of its own — but the sidebar's draft / rename field
//     lives in the SAME window, so a bare letter registered as a `keyboardShortcut`
//     (which is matched before `keyDown` reaches the first responder) would swallow a
//     keystroke mid-rename. This is why `AtelierRefsApp`'s Edit ▸ Remove carries NO
//     key equivalent for bare ⌫ (`AtelierRefsApp.swift:223-238`).
//   • The Home gallery reads its keys through SwiftUI's `.onKeyPress`, which only
//     fires while the view holds SwiftUI focus — the sidebar's rename field taking the
//     keyboard is the same event as the gallery losing it, so the guard is structural
//     rather than written down ([345]).
//
//  Every bare-letter decoder REQUIRES bare modifiers — `gridKeyCommand`'s `x` case
//  tests `bareModifiers.isEmpty`, its `m` / `a` cases test the same set minus ⇧, and
//  `toolShortcut` / `boardShortcut` share one guard rejecting ⌘ / ⌥ / ⌃ / fn — so ⌘A
//  is still Select All and ⌘M is still nobody's after K3.
//
//  Pure and SwiftUI-free, in the shape `DeleteIntent.swift` established. AppKit is
//  imported for `NSEvent.ModifierFlags` and the function-key scalars only, which is
//  what the decoders this table is checked against speak.
//

import AppKit

// MARK: - Scope

/// The surface a chord is live on. One section of the shortcuts sheet per case, in
/// declaration order — which is roughly the order a user meets them.
///
/// `.sidebar` is NOT in [024]'s original six. It was added because the sidebar grew
/// real key bindings after that doc was written (`2b5560d`: Enter renames the selected
/// row, and →/← expand/collapse the tree), and a keyboard map that omits the newest
/// bindings in the app fails its one job. The alternative — filing them under
/// `.global` — would have been false (they only fire while the outline view holds
/// first responder) and would have manufactured a collision against the grid's Return.
nonisolated enum ShortcutScope: String, CaseIterable, Hashable, Sendable {
    /// Menu key equivalents that mean the same thing on every surface.
    case global
    /// The collection grid (`MasonryGridHost` + `CollectionView`).
    case collection
    /// The full-window item detail overlay (`ItemDetailView`).
    case detail
    /// A Space board — the canvas and its floating action bar.
    case space
    /// The Home gallery of collection + space cards (`CollectionsGalleryView`).
    case gallery
    /// The search field in the panel toolbar (`LibrarySearch`).
    case search
    /// The sidebar's collection / space outlines (`SidebarOutlineKit`).
    case sidebar

    /// The sheet's section heading.
    var title: String {
        switch self {
        case .global: "Everywhere"
        case .collection: "In a Collection"
        case .detail: "Item Detail"
        case .space: "On a Space Board"
        case .gallery: "Home"
        case .search: "Search"
        case .sidebar: "Sidebar"
        }
    }

    /// One line under the heading saying when these apply.
    var note: String {
        switch self {
        case .global: "Menu commands. They work wherever you are."
        case .collection: "While the grid has the keyboard."
        case .detail: "While a single item is open full-window."
        case .space: "While the canvas has the keyboard."
        case .gallery: "The gallery of collection and space cards."
        case .search: "While the search field has the keyboard."
        case .sidebar: "While a sidebar row is selected."
        }
    }
}

// MARK: - Keys and modifiers

/// One physical key, in the two vocabularies this file needs: what a key cap should
/// SAY, and what `charactersIgnoringModifiers` a decoder will SEE for it.
nonisolated enum ShortcutKey: Hashable, Sendable {
    /// A literal character key — stored lowercase for letters, as the decoders read it.
    case character(Character)
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    /// Return / Enter.
    case returnKey
    case escape
    case space
    /// Backspace — the ⌫ every Mac keyboard has.
    case delete
    /// Forward-delete — ⌦, which IS fn-⌫ on a keyboard without the key.
    case forwardDelete

    /// What the key cap shows.
    var caption: String {
        switch self {
        case .character(let c): String(c).uppercased()
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .returnKey: "↩"
        case .escape: "esc"
        case .space: "space"
        case .delete: "⌫"
        case .forwardDelete: "⌦"
        }
    }

    /// The `charactersIgnoringModifiers` an `NSEvent` carries for this key — the
    /// string the pure decoders switch on. This is what makes the contract test
    /// possible without building an `NSEvent`.
    var characters: String {
        switch self {
        case .character(let c): String(c)
        case .upArrow: Self.functionKey(NSUpArrowFunctionKey)
        case .downArrow: Self.functionKey(NSDownArrowFunctionKey)
        case .leftArrow: Self.functionKey(NSLeftArrowFunctionKey)
        case .rightArrow: Self.functionKey(NSRightArrowFunctionKey)
        case .returnKey: "\r"
        case .escape: "\u{1b}"
        case .space: " "
        case .delete: "\u{7f}"
        case .forwardDelete: Self.functionKey(NSDeleteFunctionKey)
        }
    }

    private static func functionKey(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(code) else { return "" }
        return String(Character(scalar))
    }
}

/// The modifier set of a chord. A thin mirror of `NSEvent.ModifierFlags` so the table
/// itself stays a value type with a stable caption order.
nonisolated struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// The glyphs, in the order macOS draws them in a menu: ⌃ ⌥ ⇧ ⌘.
    var caption: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }

    /// The `NSEvent` flags a decoder is handed for this chord.
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }
}

/// One key plus its modifiers — the unit a collision is measured in. A ``Shortcut``
/// with two alternate keys (⌘= and ⌘+) is two chords.
nonisolated struct Chord: Hashable, Sendable {
    let key: ShortcutKey
    let modifiers: ShortcutModifiers

    /// The key cap's text: `⌘D`, `⇧⌘Z`, `esc`, `⌫`.
    var caption: String { modifiers.caption + key.caption }
}

// MARK: - Decoder ownership

/// Which pure decoder — if any — owns a row, so the contract test can walk the table
/// back through the code it claims to describe.
///
/// ``none`` is not a gap: a row delivered by a SwiftUI `keyboardShortcut` or an AppKit
/// menu item has no pure function to ask, and inventing one would be dispatch.
nonisolated enum ShortcutDecoder: Hashable, Sendable {
    /// `gridKeyCommand(characters:modifiers:)` — `MasonryGridHost.swift`.
    case grid
    /// `detailStepDelta(characters:modifiers:)` — `ItemDetailView.swift`.
    case detailStep
    /// `CanvasHostView.toolShortcut(characters:modifiers:)` — the CanvasRenderer package.
    case canvasTool
    /// `CanvasHostView.boardShortcut(characters:modifiers:)` — the board's bare
    /// letters that are NOT tools. `A` only (024 · K3).
    case canvasBoard
    /// `deleteIntent(characters:modifiers:)` — `DeleteIntent.swift`.
    case delete
    /// Delivered by a `keyboardShortcut` / menu item; no pure decoder to check against.
    case none
}

/// Whether a row describes a binding the app HAS, or one a later phase will add.
///
/// The distinction is load-bearing: a table row that claims a binding the app does not
/// have is a lie the collision test cannot catch, which is precisely the failure this
/// file exists to prevent. Planned rows therefore live in ``KeyMap/planned``, never in
/// ``KeyMap/all``, and the sheet does not render them.
nonisolated enum ShortcutStatus: Hashable, Sendable {
    case bound
    /// Reserved by a design doc but NOT wired. The string says which doc.
    case planned(String)
}

// MARK: - A shortcut

/// One row of the map: what you press, what it does, and where.
nonisolated struct Shortcut: Hashable, Sendable, Identifiable {
    /// One or more interchangeable keys — ⌘= and ⌘+ are one shortcut with two keys,
    /// because they are one binding a user thinks of as "bigger".
    let keys: [ShortcutKey]
    let modifiers: ShortcutModifiers
    /// The verb, as the user would say it. Sentence case, no trailing period.
    let title: String
    let scope: ShortcutScope
    /// The pure decoder that owns this row, for the contract test.
    let decoder: ShortcutDecoder
    let status: ShortcutStatus
    /// Where the binding lives, `file:line`. Prose, for whoever reads the table next.
    let source: String

    init(
        _ keys: [ShortcutKey],
        _ modifiers: ShortcutModifiers = [],
        _ title: String,
        scope: ShortcutScope,
        decoder: ShortcutDecoder = .none,
        status: ShortcutStatus = .bound,
        source: String
    ) {
        self.keys = keys
        self.modifiers = modifiers
        self.title = title
        self.scope = scope
        self.decoder = decoder
        self.status = status
        self.source = source
    }

    var id: String { "\(scope.rawValue).\(caption).\(title)" }

    /// Every chord this row claims — one per alternate key.
    var chords: [Chord] { keys.map { Chord(key: $0, modifiers: modifiers) } }

    /// The whole row as key-cap text, alternates separated: `⌘= / ⌘+`.
    var caption: String { chords.map(\.caption).joined(separator: " / ") }
}

// MARK: - The table

/// The map itself.
nonisolated enum KeyMap {

    /// The title the Help menu item and the sheet share, so the two cannot drift.
    static let pageTitle = "Keyboard Shortcuts"

    /// Every binding the app HAS, verified against the source at `ef5201d`, and the
    /// `.gallery` delete rows re-verified at [345].
    ///
    /// Ordered by scope, and within a scope roughly by how early a user meets it.
    static let all: [Shortcut] = globalShortcuts + collectionShortcuts + detailShortcuts
        + spaceShortcuts + galleryShortcuts + searchShortcuts + sidebarShortcuts

    // MARK: Everywhere

    /// Menu key equivalents that mean one thing on every surface.
    ///
    /// ⌫ is deliberately absent: Edit ▸ Remove carries NO key equivalent, because a
    /// menu key equivalent is matched before the event reaches the first responder and
    /// would swallow Backspace in every text field in the app. Each surface delivers
    /// its own bare ⌫ instead — see the `.delete`-decoder rows below.
    ///
    /// The ⌘⌫ row is the *only* one, and every surface that can delete reaches it by
    /// publishing a `DeleteVerbs` focused value — including Home as of [345]. That is
    /// why a surface never gets a ⌘⌫ row of its own: it would collide with this one,
    /// correctly, since this is matched first.
    private static let globalShortcuts: [Shortcut] = [
        Shortcut([.character("z")], [.command], "Undo",
                 scope: .global, source: "AtelierRefsApp.swift:147"),
        Shortcut([.character("z")], [.command, .shift], "Redo",
                 scope: .global, source: "AtelierRefsApp.swift:150"),
        Shortcut([.character("n")], [.command], "New collection or space",
                 scope: .global, source: "AtelierRefsApp.swift:284"),
        Shortcut([.delete, .forwardDelete], [.command], "Delete from the library…",
                 scope: .global, decoder: .delete, source: "AtelierRefsApp.swift:246 (Edit ▸ Delete)"),
        Shortcut([.character("[")], [.command], "Back",
                 scope: .global, source: "AtelierRefsApp.swift:325"),
        Shortcut([.character(",")], [.command], "Settings",
                 scope: .global, source: "AtelierRefsApp.swift:96 (Settings scene)"),
        Shortcut([.character("/")], [.command], pageTitle,
                 scope: .global, source: "AtelierRefsApp.swift (Help menu)"),
    ]

    // MARK: In a collection

    private static let collectionShortcuts: [Shortcut] = [
        Shortcut([.leftArrow, .rightArrow, .upArrow, .downArrow], [], "Move the cursor",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.leftArrow, .rightArrow, .upArrow, .downArrow], [.shift],
                 "Extend the selection",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.returnKey], [], "Open the item",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.space], [], "Quick Look",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        // The one bare-letter binding the grid has. `bareModifiers.isEmpty`, so even
        // ⇧X falls through — it never eats ⌘X.
        Shortcut([.character("x")], [], "Add or remove the cursor item",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        // 024 · K3. Bare letters, ⇧ tolerated (unlike `X`): a stray capital still meant
        // the verb, and the guard that matters is the ⌘ / ⌥ / ⌃ one below it, which is
        // what leaves ⌘A alone. Both act on the SELECTION, or — with none — on the
        // keyboard cursor's post, widened, exactly as ⌫ and ⌘D do.
        Shortcut([.character("m")], [], "Move to…",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.character("a")], [], "Add to…",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        // 023 · A3. Bare `E`, ⇧ tolerated like M / A. One key for both
        // directions: `shelfVerb` reads the selection and archives unless every
        // target already is, so E on the Archived pane puts things back.
        Shortcut([.character("e")], [], "Archive (or unarchive) the selection",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.character("a")], [.command], "Select all",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.escape], [], "Clear the selection",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.character("="), .character("+")], [.command], "Bigger tiles",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.character("-")], [.command], "Smaller tiles",
                 scope: .collection, decoder: .grid, source: "gridKeyCommand — MasonryGridHost.swift:1893"),
        Shortcut([.delete, .forwardDelete], [], "Remove from this collection",
                 scope: .collection, decoder: .delete, source: "gridKeyDown — MasonryGridHost.swift:1575"),
        Shortcut([.character("d")], [.command], "Favorite / unfavorite",
                 scope: .collection, source: "AtelierRefsApp.swift:181"),
        Shortcut([.character("c")], [.command], "Copy",
                 scope: .collection, source: "MasonryGridHost.swift:1617 (Edit ▸ Copy)"),
        Shortcut([.character("v")], [.command], "Paste into this collection",
                 scope: .collection, source: "CollectionView.swift:257"),
    ]

    // MARK: Item detail

    private static let detailShortcuts: [Shortcut] = [
        Shortcut([.leftArrow], [], "Previous item",
                 scope: .detail, decoder: .detailStep, source: "detailStepDelta — ItemDetailView.swift:1414"),
        Shortcut([.rightArrow], [], "Next item",
                 scope: .detail, decoder: .detailStep, source: "detailStepDelta — ItemDetailView.swift:1414"),
        Shortcut([.escape], [], "Back to the grid",
                 scope: .detail, source: "ItemDetailView.swift:301"),
        Shortcut([.character("-")], [.command], "Zoom out",
                 scope: .detail, source: "ItemDetailView.swift:400"),
        Shortcut([.character("0")], [.command], "Fit to the window",
                 scope: .detail, source: "ItemDetailView.swift:411"),
        Shortcut([.character("+"), .character("=")], [.command], "Zoom in",
                 scope: .detail, source: "ItemDetailView.swift:419, :439"),
        Shortcut([.delete, .forwardDelete], [], "Remove from the collection",
                 scope: .detail, decoder: .delete, source: "DetailKeyCatcher — ItemDetailView.swift:1548"),
    ]

    // MARK: On a Space board

    /// `V` / `F` / `T` are the canvas's bare-letter tools, and `toolShortcut` returns
    /// `nil` for every other letter — so the board's remaining bare letters are free.
    private static let spaceShortcuts: [Shortcut] = [
        Shortcut([.character("v")], [], "Select tool",
                 scope: .space, decoder: .canvasTool,
                 source: "toolShortcut — CanvasHostView.swift:1301"),
        Shortcut([.character("f")], [], "Frame tool",
                 scope: .space, decoder: .canvasTool,
                 source: "toolShortcut — CanvasHostView.swift:1301"),
        Shortcut([.character("t")], [], "Text tool",
                 scope: .space, decoder: .canvasTool,
                 source: "toolShortcut — CanvasHostView.swift:1301"),
        // 024 · K3. **`A` only — there is no board `M`.** [024] §C recommended M on
        // every surface with a selection; on a board it would have had to mean "file
        // the assets AND drop the placements", a destructive-adjacent composite wearing
        // the same key as the grid's plain reparent. A board owns placements, not
        // memberships (019 · C1), so `A` — file, placements untouched — is the verb it
        // actually has. Decoded beside the tools rather than as one of them: filing is
        // not a MODE the canvas can be in. See §C's amendment.
        Shortcut([.character("a")], [], "Add to… (placements stay)",
                 scope: .space, decoder: .canvasBoard,
                 source: "boardShortcut — CanvasHostView.swift:1343"),
        Shortcut([.delete, .forwardDelete], [], "Remove from the board",
                 scope: .space, decoder: .delete, source: "CanvasHostView.swift:1189"),
        Shortcut([.character("c")], [.command], "Copy the selected tiles",
                 scope: .space, source: "CanvasHostView.swift:1365"),
        Shortcut([.character("v")], [.command], "Paste onto the board",
                 scope: .space, source: "CanvasHostView.swift:1376"),
        Shortcut([.character("d")], [.command], "Duplicate the selection",
                 scope: .space, source: "SpaceView.swift:816"),
        Shortcut([.character("]")], [.command, .shift], "Bring to front",
                 scope: .space, source: "SpaceView.swift:840"),
        Shortcut([.character("[")], [.command, .shift], "Send to back",
                 scope: .space, source: "SpaceView.swift:843"),
        Shortcut([.character("e")], [.command, .shift], "Export moodboard…",
                 scope: .space, source: "MoodboardExportControls.swift:138"),
    ]

    // MARK: Home

    /// Home follows the two-tier rule as of [345]. It did not when this table was
    /// written: a bare ⌫ deleted the selected collections and spaces outright, because
    /// SwiftUI's `.onDeleteCommand` is handed no modifiers and so could not route
    /// through `deleteIntent` at all. `.onDeleteCommand` is gone; a `.onKeyPress` over
    /// the shared decoder replaced it.
    ///
    /// **⌘⌫ is not a row here, and that is the point.** Deleting cards from Home is
    /// Edit ▸ Delete — the `.global` row above — which the gallery now feeds a
    /// `DeleteVerbs`. A second `.gallery` row on the same chord would be the exact
    /// `.global`-shadows-a-surface case ``collisions(in:)`` exists to catch: a menu key
    /// equivalent is matched before the first responder is consulted, so a local
    /// binding could only ever lose to it.
    private static let galleryShortcuts: [Shortcut] = [
        Shortcut([.character("a")], [.command], "Select all cards",
                 scope: .gallery, source: "CollectionsGalleryView.swift:114"),
        // Bound, and it does nothing on purpose — Home is not a container, so there is
        // no membership for ⌫ to drop. It is a row rather than an omission because the
        // app really does claim the key: it posts a notice naming ⌘⌫, which is what
        // muscle memory trained on the old destructive binding needs to be told.
        Shortcut([.delete, .forwardDelete], [], "Nothing — ⌘⌫ deletes the cards",
                 scope: .gallery, decoder: .delete,
                 source: "galleryDeleteIntent — CollectionsGalleryView.swift:110, :588"),
        Shortcut([.escape], [], "Clear the selection",
                 scope: .gallery, source: "CollectionsGalleryView.swift:113"),
    ]

    // MARK: Search

    private static let searchShortcuts: [Shortcut] = [
        Shortcut([.character("f")], [.command], "Search this library",
                 scope: .search, source: "LibrarySearch.swift:625"),
        Shortcut([.escape], [], "Clear the query",
                 scope: .search, source: "LibrarySearch.swift:596"),
    ]

    // MARK: Sidebar

    /// →/← and ↑/↓ are `NSOutlineView`'s own — `SidebarOutlineView.onKeyDown` returns
    /// `false` for everything but Return precisely so they stay native. They are listed
    /// because a reference card that omits them is wrong about the app, not because the
    /// app implements them.
    private static let sidebarShortcuts: [Shortcut] = [
        Shortcut([.upArrow, .downArrow], [], "Move between rows",
                 scope: .sidebar, source: "SidebarOutlineKit.swift:36 (native)"),
        Shortcut([.rightArrow], [], "Expand the folder",
                 scope: .sidebar, source: "SidebarOutlineKit.swift:36 (native)"),
        Shortcut([.leftArrow], [], "Collapse the folder",
                 scope: .sidebar, source: "SidebarOutlineKit.swift:36 (native)"),
        Shortcut([.returnKey], [], "Rename the row",
                 scope: .sidebar, source: "CollectionsOutlineView.swift:670"),
    ]

    // MARK: - Planned, NOT bound

    /// Chords a design doc has reserved but nothing yet delivers.
    ///
    /// Kept OUT of ``all`` on purpose. [024] is explicit that "a table row without a
    /// binding is a lie the collision test cannot catch", so the sheet renders only
    /// `all` and a user is never told about a key that does nothing. They are still
    /// worth writing down, because the collision test runs over `all + planned` too: a
    /// phase that is about to take a reserved chord gets a build failure instead of
    /// discovering the clash by hand.
    ///
    /// **Empty as of [024] K3**, which was the reason it was written: the four `M` /
    /// `A` rows it held are now bound (three of them — the board's `M` was dropped,
    /// see the `.space` section above). The array and ``ShortcutStatus`` stay because
    /// they are the SEAM, not the rows: the next doc-reserved chord is a one-line
    /// addition here and inherits the collision check for free. Deleting them would
    /// mean rebuilding the mechanism the first time it is wanted again — and, worse,
    /// would invite the next reservation into `all`, which is the lie the split exists
    /// to prevent.
    static let planned: [Shortcut] = []

    // MARK: - Queries

    /// The bound rows for one scope, in table order.
    static func shortcuts(in scope: ShortcutScope) -> [Shortcut] {
        all.filter { $0.scope == scope }
    }

    /// Scopes that have at least one bound row, in declaration order — the sheet's
    /// sections. A scope that loses its last binding loses its heading rather than
    /// rendering an empty card.
    static var populatedScopes: [ShortcutScope] {
        ShortcutScope.allCases.filter { scope in all.contains { $0.scope == scope } }
    }

    // MARK: - Collisions

    /// Two rows that claim the same chord somewhere both are live.
    nonisolated struct Collision: Hashable, Sendable {
        let chord: Chord
        let first: Shortcut
        let second: Shortcut

        var description: String {
            "\(chord.caption): “\(first.title)” (\(first.scope.rawValue), \(first.source)) "
                + "vs “\(second.title)” (\(second.scope.rawValue), \(second.source))"
        }
    }

    /// Every pair of rows sharing a chord in an overlapping scope — **the reason this
    /// table exists.**
    ///
    /// Two scopes overlap when they are the same, or when either is ``ShortcutScope/global``
    /// (a menu key equivalent is live on top of every surface). Anything else is fine
    /// by construction: ⌘D can be Favorite on a grid and Duplicate on a board because
    /// only one of those surfaces has the keyboard at a time.
    static func collisions(in shortcuts: [Shortcut]) -> [Collision] {
        var found: [Collision] = []
        for (index, first) in shortcuts.enumerated() {
            for second in shortcuts[shortcuts.index(after: index)...] {
                guard scopesOverlap(first.scope, second.scope) else { continue }
                let shared = Set(first.chords).intersection(second.chords)
                for chord in shared.sorted(by: { $0.caption < $1.caption }) {
                    found.append(Collision(chord: chord, first: first, second: second))
                }
            }
        }
        return found
    }

    /// Whether a chord bound in both scopes could fire in the same moment.
    static func scopesOverlap(_ a: ShortcutScope, _ b: ShortcutScope) -> Bool {
        a == b || a == .global || b == .global
    }

    // MARK: - Where you are

    /// The scope whose section the sheet should open on, from the two pieces of state
    /// that already say where the user is.
    ///
    /// Item detail wins over the sidebar selection: the overlay is what has the
    /// keyboard while it is up, and it is raised from a collection, so reading
    /// `sidebarSelection` alone would always answer `.collection` behind it.
    static func scope(
        forSidebar selection: SidebarItem, isShowingItemDetail: Bool
    ) -> ShortcutScope {
        if isShowingItemDetail { return .detail }
        switch selection {
        case .collection: return .collection
        case .space: return .space
        case .home: return .gallery
        default: return .global
        }
    }
}
