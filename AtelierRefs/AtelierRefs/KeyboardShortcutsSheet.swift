//
//  KeyboardShortcutsSheet.swift
//  AtelierRefs
//
//  024 · K2 — the shortcuts page. Every row is read from ``KeyMap/all``; this file
//  invents no bindings and knows no chords of its own.
//
//  **A sheet, not a Settings tab.** Settings is where things you CHANGE live; this is
//  reference material you open mid-task, read, and dismiss. It is reached from
//  Help ▸ Keyboard Shortcuts (⌘/) — the chord users arrive with, and the one [024] · D
//  confirmed was unbound.
//
//  **Scope-aware.** The section for the surface you were on when you opened it is
//  marked and scrolled to, so the sheet opens on the answer rather than on a
//  table of contents. `NavModel` already knows where you are
//  (`sidebarSelection` + `presentedItemID`); the mapping is
//  ``KeyMap/scope(forSidebar:isShowingItemDetail:)``, kept pure and unit-tested.
//
//  **⌘D appears twice, under two headings**, as *Favorite* in "In a Collection" and
//  *Duplicate* in "On a Space Board". That is the decision, not a bug: both meanings
//  stay and the scope headings carry the distinction. The rendering leans on that —
//  every section states which surface it applies to in its own subtitle, and the
//  duplicated chord is the reason those subtitles exist.
//
//  Chrome is the app's existing vocabulary: `surface` cards on a `hairline` border at
//  `Radius.card` (the ``AppShellView`` Capture-pane idiom), `Theme.Typography` roles,
//  and key caps drawn as `field` chips — the same raised grey the theme uses for
//  emphasis. Nothing new is invented here.
//

import SwiftUI

struct KeyboardShortcutsSheet: View {
    /// The surface the user was on when they opened the sheet — its section is
    /// marked and scrolled to.
    let currentScope: ShortcutScope
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Colors.hairline)
            sections
            Divider().overlay(Theme.Colors.hairline)
            footer
        }
        .frame(width: Layout.width, height: Layout.height)
        .background(Theme.Colors.panel)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(KeyMap.pageTitle)
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.inkPrimary)
            Spacer()
            // `.cancelAction` is what binds Escape on a sheet: without it the sheet has
            // no cancel button and Escape is bound to nothing at all (the same
            // mechanism ``ContentView``'s delete dialog documents from the other side).
            Button("Done", action: onDone)
                .buttonStyle(DialogButtonStyle(width: .hug))
                .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.lg)
    }

    private var sections: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(KeyMap.populatedScopes, id: \.self) { scope in
                        ScopeCard(scope: scope, isCurrent: scope == currentScope)
                            .id(scope)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            // Deferred to a `task` rather than `onAppear`: the scroll view has no
            // content geometry during the first layout pass, so a scroll issued there
            // lands on nothing. `.global` is skipped — it is already the top section,
            // and scrolling to it would look like the sheet had ignored the request.
            .task {
                guard currentScope != .global else { return }
                proxy.scrollTo(currentScope, anchor: .top)
            }
        }
    }

    /// Said out loud rather than left implied: a rebinding UI is the first thing this
    /// page will be asked for, and "not yet" in the page itself is a cheaper answer
    /// than a bug report.
    private var footer: some View {
        Text("These can't be changed yet — custom shortcuts aren't in this version.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
    }

    private enum Layout {
        /// Wide enough that the longest verb ("Remove from this collection") and its
        /// caps sit on one line without the caps floating away from it.
        static let width: CGFloat = 560
        static let height: CGFloat = 640
    }
}

// MARK: - One scope

/// One section: a heading, the line saying when it applies, and its rows.
private struct ScopeCard: View {
    let scope: ShortcutScope
    /// The section for the surface the sheet was opened from.
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(scope.title)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.Colors.inkPrimary)
                if isCurrent { hereChip }
            }
            // The subtitle is load-bearing, not decoration: ⌘D is Favorite in one
            // section and Duplicate in another, and this line is what makes that read
            // as two surfaces rather than one contradiction.
            Text(scope.note)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(KeyMap.shortcuts(in: scope)) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.surface, in: shape)
        .overlay(shape.strokeBorder(
            isCurrent ? Theme.Colors.hairlineStrong : Theme.Colors.hairline))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    /// "You are here". A `field` chip, the app's own emphasis fill — there is no
    /// coloured accent to reach for (see ``Theme``'s header).
    private var hereChip: some View {
        Text("Where you are")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                Theme.Colors.field,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

// MARK: - One row

private struct ShortcutRow: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(shortcut.title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(shortcut.chords, id: \.self) { chord in
                    KeyCap(caption: chord.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortcut.title), \(shortcut.caption)")
    }
}

/// One key cap. A `field` chip on a `hairlineStrong` border — the raised grey the
/// theme uses for emphasis, at the same radius every other small rounded thing uses.
/// `monospacedDigit` is deliberate: `⌘0` and `⌘=` should not shuffle the cap width.
private struct KeyCap: View {
    let caption: String

    var body: some View {
        Text(caption)
            .font(Theme.Typography.label)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 26)
            .background(
                Theme.Colors.field,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong))
    }
}

#Preview {
    KeyboardShortcutsSheet(currentScope: .collection) {}
}
