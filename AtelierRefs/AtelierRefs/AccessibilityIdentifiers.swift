//
//  AccessibilityIdentifiers.swift
//  AtelierRefs
//
//  099 · P2 — the handful of names the macOS smoke target asserts on.
//
//  **Why a file, and why only four.** Before this phase the Mac target had exactly zero
//  `accessibilityIdentifier` calls (467), so a UI test could only match on visible text —
//  and the visible text is ambiguous the moment two surfaces name the same thing. The
//  seeded library's "Textures" appears on a Home card AND on a sidebar row; a test that
//  matched the string would pass while asserting the wrong element. These four names are
//  what the three smoke flows need to say WHICH element they mean, and nothing else was
//  added: an identifier that no test reads is a maintenance cost with no reader.
//
//  **Leaves only** (098's rule, and it is a demonstrated bug class rather than a style
//  note): on the phone, `export.sent` on an enclosing `VStack` renamed everything inside
//  it and neither child could be found at runtime. Every name below lands on the element
//  that IS the accessibility leaf — a SwiftUI `Button` whose label SwiftUI has already
//  merged, a leaf `Text`, an AppKit `NSTextField`, an AppKit `NSButton`. Nothing here is
//  attached to a container, and no `.accessibilityElement(children:)` was changed to make
//  a flow easier.
//
//  **The UI-test bundle re-spells these.** `AtelierRefsUITests` is a second process
//  running against the built app, not a `@testable import`, so it cannot see this enum —
//  its `Fixture` enum carries the same strings and each side's comment names the other.
//  That is the same seam 098 accepted between `FixtureLibrary.Names` and the phone's
//  suites, and the reason both sides are small.
//
//  Not `#if DEBUG`: an accessibility identifier is inert metadata that ships with every
//  other accessibility affordance, and a Release build that differs from the tested one
//  in what its elements are called is a worse trade than four strings in the binary.
//

import Foundation

/// The accessibility identifiers the macOS UI tests match on (099 · P2).
enum AccessibilityID {

    // MARK: - Home

    /// A Home gallery card for a collection. The card's Button is the accessibility
    /// element — SwiftUI merges the fan, the title and the count into its label — so
    /// this is the leaf, not a container around one.
    ///
    /// Per-collection rather than a constant because the flow asserts a NAMED card is
    /// there; a shared identifier would only let a test count cards.
    static func homeCollectionCard(_ name: String) -> String { "home.collection.\(name)" }

    // MARK: - Sidebar (the AppKit collections tree)

    /// The prefix every collections-tree row carries. Spelled separately from
    /// ``sidebarCollectionRow(_:)`` because the order assertion matches on the PREFIX —
    /// it asks the window for every collection row, in hierarchy order, and compares the
    /// list — rather than looking up one row at a time.
    static let sidebarCollectionRowPrefix = "sidebar.collection."

    /// One row of the collections tree, on its `NSTextField` label.
    static func sidebarCollectionRow(_ name: String) -> String {
        sidebarCollectionRowPrefix + name
    }

    /// A collections-tree row's disclosure button — the control that reveals a nested
    /// collection. `NSOutlineView` starts collapsed and this app does not autosave
    /// expansion (`autosaveExpandedItems = false`), so a nested row is not in the
    /// hierarchy at all until this is clicked.
    static func sidebarCollectionDisclosure(_ name: String) -> String {
        sidebarCollectionRow(name) + ".disclosure"
    }

    // MARK: - Settings

    /// The capture endpoint's value in the Settings scene (⌘,).
    ///
    /// The flow needs SOMETHING that only the Settings window has, so that "a second
    /// window exists" can be sharpened into "the second window is Settings". This row is
    /// the first thing the Form draws and it is a plain leaf `Text`.
    static let settingsCaptureEndpoint = "settings.capture.endpoint"
}

// MARK: - The ⌘K switcher (099 · P5)

extension AccessibilityID {

    /// The switcher panel's query field. A single constant rather than a per-name
    /// spelling because there is exactly one of them, and because the flow's whole
    /// point is to type into it before it knows what it will find.
    static let switcherField = "switcher.field"

    /// One destination row in the switcher, by the name it shows.
    ///
    /// Per-name for ``homeCollectionCard(_:)``'s reason: the flow asserts that a
    /// NAMED destination is offered, and a shared identifier would only let a test
    /// count rows. On the row's `Button`, which SwiftUI has already merged into one
    /// accessibility element — a leaf, per this file's header.
    static func switcherRow(_ name: String) -> String { "switcher.row.\(name)" }

    /// The collection pane's title, by the name it shows — what "the grid now shows
    /// this collection" is asserted through.
    ///
    /// On the leaf `Text`, not the header row that contains it and the item count.
    /// The header is also rendered HIDDEN off-screen to measure its natural height
    /// (`CollectionView.headerContent`), and a hidden SwiftUI view is out of the
    /// accessibility tree — so this still names one element, but a flow reading it
    /// should say `.firstMatch` and not depend on that.
    static func collectionTitle(_ name: String) -> String { "collection.title.\(name)" }
}
