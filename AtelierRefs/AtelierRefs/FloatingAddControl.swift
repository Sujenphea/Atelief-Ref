//
//  FloatingAddControl.swift
//  AtelierRefs
//
//  The floating "+" as a PANE-level affordance. It used to hang off the shell
//  (`AppShellView`), one button for the whole window, which forced its menu to be a
//  lowest-common-denominator guess at what the visible pane could add — and put it on
//  panes with nothing to add at all (Settings, Capture, Home). Worse, a shell-level
//  button is outside `SpaceView`, and `SpaceModel` — the only writer that reloads an
//  OPEN board — lives inside it, so "add to this space" was structurally unreachable.
//
//  So the "+" moved down. A pane opts in with `.floatingAdd(...)`, which supplies both
//  the standard placement and the popover host an `NSMenu` cannot be.
//

import SwiftUI

// MARK: - The control

/// The pane's floating "+": the AppKit disc, its menu, and the popover forms some of
/// that menu's entries raise.
///
/// The popover lives HERE rather than in ``FloatingAddButton`` because an `NSMenu`
/// can't host SwiftUI: picking "Add Color…" only names a body, and this view presents
/// it, anchored on the button so the form appears where the click landed.
struct FloatingAddControl: View {
    var diameter: CGFloat = 40
    let items: [FloatingAddItem]

    /// The title of the entry whose popover is open, or `nil`. Keyed by title (see
    /// ``FloatingAddItem``) so it survives the body rebuilds that happen while a form
    /// is on screen.
    @State private var openPopover: String?

    var body: some View {
        FloatingAddButton(diameter: diameter, items: menuItems)
            .frame(width: diameter, height: diameter)
            // `.top` opens the form ABOVE the button — the same trick the selection
            // bar's overflow uses to escape a bottom-anchored control.
            .popover(isPresented: isShowingPopover, arrowEdge: .top) { popoverBody }
    }

    /// The items handed to the `NSMenu`, with every popover entry's action rewritten to
    /// RAISE that popover instead. Deferred a runloop turn: the action fires from inside
    /// the menu's modal tracking loop, and presenting a popover while that loop is still
    /// unwinding leaves the popover without a window to attach to.
    private var menuItems: [FloatingAddItem] {
        items.map { item in
            guard item.popover != nil else { return item }
            return FloatingAddItem(
                title: item.title, systemImage: item.systemImage,
                action: { DispatchQueue.main.async { openPopover = item.title } })
        }
    }

    private var isShowingPopover: Binding<Bool> {
        Binding(get: { openPopover != nil }, set: { if !$0 { openPopover = nil } })
    }

    /// The open entry's form, handed the closure that closes it once it commits.
    @ViewBuilder
    private var popoverBody: some View {
        if let openPopover, let item = items.first(where: { $0.title == openPopover }),
           let content = item.popover {
            content { self.openPopover = nil }
        }
    }
}

// MARK: - Placement

extension View {
    /// Float a "+" over this pane's bottom-trailing corner, opening `items` as a menu.
    ///
    /// `isPresented` is the pane's own visibility rule — pass `false` while a
    /// full-window overlay is up, since the "+" is an overlay on the PANE and would
    /// otherwise draw on top of a detail page it has nothing to do with.
    ///
    /// The 16pt inset is `selectionBarChrome()`'s bottom inset, so the "+" and the
    /// floating action bar share a baseline when both are on screen. (The shell-level
    /// button used to add 24/26 on top of the panel's own 12pt margins, landing at
    /// 12/14 from the panel edge — near the bar, but never on it.)
    func floatingAdd(isPresented: Bool = true, items: [FloatingAddItem]) -> some View {
        overlay(alignment: .bottomTrailing) {
            if isPresented, !items.isEmpty {
                FloatingAddControl(items: items)
                    .padding(.trailing, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.lg)
            }
        }
    }

    /// Float a "+" that runs ONE action on click, with no menu — for a pane with a
    /// single thing to add. `help` is the tooltip, and the only label a bare disc has.
    func floatingAdd(
        isPresented: Bool = true, help: String, action: @escaping () -> Void
    ) -> some View {
        overlay(alignment: .bottomTrailing) {
            if isPresented {
                FloatingAddButton(diameter: 40, directAction: action, help: help)
                    .frame(width: 40, height: 40)
                    .padding(.trailing, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.lg)
            }
        }
    }
}
