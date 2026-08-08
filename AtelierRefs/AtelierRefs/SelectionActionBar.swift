//
//  SelectionActionBar.swift
//  AtelierRefs
//
//  The app's floating-bar kit, and the "N selected" bar built from it.
//
//  ``floatingBarChrome(leading:trailing:vertical:)`` is the ONE container every bar
//  that rides over content wears — the three selection bars, the board's action bar,
//  the detail zoom controls and top-bar pills, the text format bubble, the import
//  pill, the toast. ``BarGlyphSlot`` (and its ``SelectionBarIcon`` /
//  ``CompactBarIcon`` faces) is the one button unit. The full rule set, including
//  what is deliberately NOT unified, is `.docs/079-floating-bars-design.md`.
//
//  ``CountSelectionBar`` is the bar itself: a monochrome capsule with a leading
//  "N selected" count, an `×` clear, a delete, and a trailing slot for whatever else
//  the host offers. Home, Search and a Collection all render it — they used to hold
//  three private copies, two of them byte-identical, which is how the label font and
//  the missing disabled dim came to need fixing in three places.
//
//  Chrome only — every button calls back into the owning view's model.
//

import SwiftUI

// MARK: - Icon glyph

/// The styled glyph shared by every bar button: a fixed 30×28 hit area with a
/// subtle rounded hover fill, so the row reads as a tidy group of taps rather than
/// crowded symbols. Reused directly as the `Menu`/popover trigger label too, which
/// is why it's split out from `SelectionBarButton`.
///
/// **The app has exactly two glyph units, and the rule is where the glyph sits.**
/// This one — 30×28, `Radius.control`, a 15pt medium symbol — is for a STANDALONE
/// floating bar: the selection bars, the board's action bar, the detail zoom
/// controls, the text format bubble. ``CompactBarIcon`` is for a glyph nested INSIDE
/// another pill, where 28pt of hit area cannot fit. Before this split there were
/// four sizes and two radii for the same class of button, because each bar sized its
/// own; a bar that is 40pt tall in one place and 29 in another is not one control.
///
/// `isOn` marks a glyph that carries STATE rather than firing an action — the board's
/// Select / Frame / Text tools. It takes the raised `selection` fill, which is how a
/// sidebar row and a chip already mark "this is the live one"; the hover fill steps
/// aside underneath it so a pointer can't wash the marker out.
struct SelectionBarIcon: View {
    let systemName: String
    var isOn = false

    var body: some View {
        BarGlyphSlot(isOn: isOn) {
            Image(systemName: systemName).font(.system(size: 15, weight: .medium))
        }
    }

    /// The unit, published so a non-glyph item can claim the same slot — the export
    /// progress ring is 16pt of drawing and would otherwise dent the row.
    static let width: CGFloat = 30
    static let height: CGFloat = 28
}

/// The glyph unit for a button nested INSIDE another pill — today only the detail
/// pager's chevrons, which live in a 28pt-tall pill that a 28pt glyph would fill
/// edge to edge.
///
/// Same treatment as ``SelectionBarIcon``, one step down: 24×22 on `Radius.chip`
/// with a 13pt symbol. It exists so "smaller because it is nested" is a stated rule
/// with one size behind it, rather than whatever each pill's `HoverButtonStyle`
/// padding happened to produce.
struct CompactBarIcon: View {
    let systemName: String

    var body: some View {
        BarGlyphSlot(width: 24, height: 22, cornerRadius: Theme.Radius.chip) {
            Image(systemName: systemName).font(.system(size: 13, weight: .medium))
        }
    }
}

/// The bar glyph's SLOT, without assuming the content is an SF Symbol.
///
/// ``SelectionBarIcon`` and ``CompactBarIcon`` are this with a symbol in them; the
/// format bubble's segments are this with a swatch dot, an "Aa" specimen and a point
/// size in them. Splitting it out is what let the bubble join the system: its
/// segments were plain `.buttonStyle(.plain)` labels with no hover treatment at all —
/// the one row of buttons in the app that stayed inert under the pointer — because
/// the shared hover fill was welded to `Image(systemName:)`.
struct BarGlyphSlot<Content: View>: View {
    var width: CGFloat = SelectionBarIcon.width
    var height: CGFloat = SelectionBarIcon.height
    var cornerRadius: CGFloat = Theme.Radius.control
    var isOn = false
    @ViewBuilder var content: Content

    @State private var isHovering = false
    /// Dimming is the ATOM's job, not the call site's. `.buttonStyle(.plain)` drops
    /// the system's own disabled treatment, so every bar button used to re-apply
    /// `.opacity(0.35)` by hand — and the two collection-bar export buttons simply
    /// forgot, staying fully bright while unavailable. Reading the environment here
    /// makes the dim unforgettable and deletes it from six call sites.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : Theme.disabledOpacity)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        if isOn { return Theme.Colors.selection }
        return isHovering && isEnabled ? Theme.Colors.hoverControl : .clear
    }
}

// MARK: - Action button

/// One action icon in the selection bar. `role` stays cosmetic here — `.plain`
/// keeps every glyph the same monochrome ink (the reference's trash is white, not
/// red); the destructive confirmation lives in the model call, not the tint.
struct SelectionBarButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole?
    var action: () -> Void

    init(_ systemName: String, help: String, role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            SelectionBarIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        // `inkPrimary`, not `.primary`. The system semantic resolves to pure #FFFFFF
        // on a dark appearance, while every other piece of chrome — the mode buttons
        // beside these, the format bubble, every panel — draws the warmer #F2F1EE
        // token. The board's action bar carried both, so one row rendered two whites.
        .foregroundStyle(Theme.Colors.inkPrimary)
        .help(help)
    }
}

// MARK: - Mode button

/// A bar glyph that reports a MODE rather than firing an action — one of a small
/// mutually exclusive set, of which exactly one is live. The board's Select / Frame /
/// Text tools are the only such set today.
///
/// This exists so a mode row can live in the bar wearing the bar's own vocabulary. It
/// used to be a `.pickerStyle(.segmented)` `Picker`, whose AppKit bezel and accent-
/// tinted segment are the two things this app's chrome does not have (`Theme`:
/// "there is NO coloured accent"), and whose control height and hard edges made it the
/// one child of the row that didn't line up with its neighbours —
/// ``DialogControls``'s ``SegmentedControl`` was already the token-built replacement
/// everywhere else.
///
/// It is NOT a third segmented idiom. `SegmentedControl` marks the current value with
/// an OUTLINE because it sits on a popover's `surface`, where another raised grey
/// would read as a third layer. A floating bar has the opposite constraint — it marks
/// active with a raised fill, like the sidebar row and the chip — so the same control
/// in here would be the drift, not the consistency.
struct SelectionBarModeButton: View {
    let systemName: String
    let help: String
    let isOn: Bool
    var action: () -> Void

    init(_ systemName: String, help: String, isOn: Bool, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SelectionBarIcon(systemName: systemName, isOn: isOn)
        }
        .buttonStyle(.plain)
        // The off glyphs stay legible rather than dimmed to `Theme.disabledOpacity` —
        // that is the bar's DISABLED look, and an inactive tool is one click away,
        // not unavailable.
        .foregroundStyle(isOn ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
        .help(help)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Chrome

extension View {
    /// **The** floating-bar container. Every bar that rides over content it did not
    /// lay out wears this: the three selection bars, the board's action bar, the
    /// detail zoom controls and top-bar pills, the text format bubble, the import
    /// pill, the toast.
    ///
    /// The fill is the SOLID `field` token, not `.regularMaterial`: a translucent
    /// material tints from whatever content sits behind it, so the same bar rendered a
    /// different grey over a grid than over artwork. A fixed token makes every host
    /// pixel-identical and matches the reference's opaque pill.
    ///
    /// It takes APPEARANCE only. It used to end with `.padding(.bottom, 16)`, which is
    /// placement — so the modifier could only ever be used at the bottom of a pane, and
    /// a caller that wanted the look somewhere else had to copy the four lines instead.
    /// Three did exactly that (the zoom controls, the import pill and the format
    /// bubble), and the four copies had already drifted apart on padding and shape by
    /// the time they were counted. Call sites now supply their own inset.
    ///
    /// The default insets are asymmetric — 16 leading against 8 trailing — because a
    /// bar that OPENS WITH TEXT needs the count to breathe while the last glyph's own
    /// 30×28 hit area already supplies most of the right margin. An icon-only bar
    /// passes `trailing: 16` to balance it; that is the one knob, and it is a knob
    /// rather than a second modifier because it is the only thing that legitimately
    /// varies.
    ///
    /// **Why 8 and not 6.** 6 was the first answer, and it is right for the RESTING
    /// bar: a 15pt symbol centred in the 30×28 slot carries ~7.5pt of its own air, so
    /// at 6 the symbol sits 13.5pt from the border against 12.5pt above and below it —
    /// as near even as the two axes get.
    ///
    /// It is wrong for the HOVERED bar, and the reason is the cap. A hover fill is the
    /// slot's full 30×28 rounded rect, and the capsule's trailing end is a 20pt-radius
    /// arc that curves AWAY from it. Measured across the fill's height at `trailing:
    /// 6`, the gap to the border runs 6.0 at the centre line, 4.7 at 7pt up, and
    /// **4.0 at 10pt up** before the fill's own corner turns in — a third tighter than
    /// the flat 6pt every other glyph in the row gets above and below it, at the one
    /// corner the eye lands on. At 8 that minimum comes to exactly 6.0, so the last
    /// button is evenly inset on all three sides in the state where the inset is
    /// actually drawn. The resting symbol pays 2pt for it.
    func floatingBarChrome(
        leading: CGFloat = Theme.Spacing.lg,
        trailing: CGFloat = Theme.Spacing.sm,
        vertical: CGFloat = 6
    ) -> some View {
        self
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.vertical, vertical)
            .background(Theme.Colors.field, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
            .elevation(.floating)
    }

    /// Wrap the `…` overflow popover's content in the design-system container — the
    /// shared ``popoverChrome(cornerRadius:)`` surface — and make the host popover's
    /// own chrome transparent so ONLY this card shows. Fixed width so the section
    /// headers and rows all align. Replaces the raw system-menu look.
    func selectionMenuChrome() -> some View {
        // `xs`, not the `lg` every other popover takes: this one's ROWS carry their
        // own inset (they are the click targets), so a wide outer pad would double it.
        popoverContent(padding: Theme.Spacing.xs, width: 220)
    }
}

extension View {
    /// Give a non-glyph bar item the glyph's own 30×28 slot, so a row of
    /// ``SelectionBarIcon``s keeps its rhythm around it.
    ///
    /// For the export progress ring, which draws 16pt of stroke: without this the
    /// bar visibly narrowed the moment an export started and widened again when it
    /// finished. Applied INSIDE each of the ring's branches rather than to the
    /// enclosing `Group` — a `Group` whose branches all fail contributes no subview
    /// at all, which is what keeps an idle bar from reserving an empty slot, and a
    /// frame on the outside would take that away.
    func barSlot() -> some View {
        frame(width: SelectionBarIcon.width, height: SelectionBarIcon.height)
    }
}

// MARK: - The count bar

/// The floating "N selected" bar itself — Home, Search and a Collection all show
/// this one view.
///
/// The three used to be three private `selectionBar` properties, and Search's and
/// Home's were byte-identical apart from which store they cleared. That duplication
/// is where the drift in this pass started: the raw `.callout.weight(.medium)` label
/// font was written out three times, so correcting it meant finding all three.
///
/// `extras` is the trailing slot. Search and Home pass nothing and get the plain
/// Clear + Delete pair; a Collection passes its remove / contact-sheet / web-page /
/// progress-ring / overflow glyphs. The slot sits AFTER Delete because the fixed
/// leading run — count, Clear, Delete — is the part a reader learns once and expects
/// in the same place on all three screens.
///
/// It supplies no bottom inset: the chrome is appearance only (see
/// ``floatingBarChrome(leading:trailing:vertical:)``), so the host decides where the
/// bar sits, and the host is the only thing that knows whether an import pill is
/// stacked above it.
struct CountSelectionBar<Extras: View>: View {
    let count: Int
    var deleteHelp: String
    var onClear: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var extras: Extras

    init(
        count: Int,
        deleteHelp: String? = nil,
        onClear: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder extras: () -> Extras = { EmptyView() }
    ) {
        self.count = count
        self.deleteHelp = deleteHelp ?? "Delete \(count)"
        self.onClear = onClear
        self.onDelete = onDelete
        self.extras = extras()
    }

    var body: some View {
        HStack(spacing: 2) {
            Text("\(count) selected")
                .font(Theme.Typography.barLabel)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .padding(.trailing, 10)
            SelectionBarButton("xmark", help: "Clear selection", action: onClear)
            // Every caller's delete runs its own confirmation, so no extra dialog here.
            SelectionBarButton("trash", help: deleteHelp, role: .destructive, action: onDelete)
            extras
        }
        .floatingBarChrome()
    }
}

// MARK: - Overflow popover atoms

/// Carries a destination list's measured natural height up so its capped
/// `ScrollView` can size to `min(content, cap)` (a bare ScrollView collapses to
/// zero in a content-sized popover).
struct MenuListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A collapsible section header for the selection bar's `…` overflow popover (e.g.
/// "Move to" / "Add to"). Mirrors the sidebar's `sectionHeader` idiom — a leading
/// glyph + title with a trailing chevron that swaps open/closed — so the popover
/// reads as part of the design system rather than a raw menu.
struct SelectionMenuSectionHeader: View {
    let title: String
    let systemImage: String?
    let isExpanded: Bool
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, systemImage: String? = nil, isExpanded: Bool,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isExpanded = isExpanded
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16)
                }
                Text(title)
                    .font(Theme.Typography.row)
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(isHovering ? Theme.Colors.hoverRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One tappable row in the overflow popover — a destination collection or a leaf
/// action (Set as Cover). Full-width with the app's radius-6 `hoverRow` fill (the
/// `SidebarView` nav-row idiom), 14pt ink. Pass `isEnabled: false` for a
/// non-tappable empty-state row ("No collections").
struct SelectionMenuRow: View {
    let title: String
    let systemImage: String?
    let indent: Int
    let isEnabled: Bool
    /// The KEYBOARD cursor is on this row (024 · K3) — marked with the raised
    /// `selection` fill, the same "this is the live one" the sidebar row and the chip
    /// use, and the fill hover steps aside for so a pointer can't wash it out. Default
    /// `false`, so every pointer-driven list is unchanged.
    let isHighlighted: Bool
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, systemImage: String? = nil, indent: Int = 0,
         isEnabled: Bool = true, isHighlighted: Bool = false,
         action: @escaping () -> Void = {}) {
        self.title = title
        self.systemImage = systemImage
        self.indent = indent
        self.isEnabled = isEnabled
        self.isHighlighted = isHighlighted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16)
                }
                Text(title)
                    .font(Theme.Typography.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isEnabled ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
            .padding(.leading, Theme.Spacing.sm + CGFloat(indent + 1) * 8)
            .padding(.trailing, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(rowFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { if isEnabled { isHovering = $0 } }
    }

    /// The keyboard cursor outranks the pointer: while both are on a row the raised
    /// `selection` fill wins, so a mouse resting anywhere in the list can never make
    /// the row Return would file into ambiguous.
    private var rowFill: Color {
        if isHighlighted { return Theme.Colors.selection }
        return isEnabled && isHovering ? Theme.Colors.hoverRow : .clear
    }
}
