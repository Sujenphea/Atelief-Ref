//
//  DialogControls.swift
//  AtelierRefs
//
//  The CONTENTS of a popover, on the token system. `Theme`'s `popoverChrome()` /
//  `popoverContent()` gave every popover one container, and that is where it stopped:
//  inside the card the controls were still stock macOS — `.roundedBorder` fields,
//  `.pickerStyle(.segmented)`, default push buttons, `LabeledContent` — so a popover
//  read as an app-styled frame around a system dialog.
//
//  The reference frames fix a single language for what goes inside: 1pt
//  `hairlineStrong`-outlined controls with NO fill, a label in `inkSecondary` with its
//  control right-aligned, and a full-width outlined primary action at the bottom.
//
//  SELECTION IS AN OUTLINE HERE, not a fill. That is the one place this diverges from
//  the rest of the chrome — a sidebar row, a chip and a floating bar all mark "active"
//  with a raised `field` / `selection` fill. Inside a popover the card is already
//  `surface` and a second raised grey reads as a third layer, so the segments mark the
//  current value by gaining a border instead. `SegmentedControl` is the app's ONE
//  segmented idiom (the search keyword/meaning toggle and the grid bake-off window's
//  two switches included) so they cannot drift.
//
//  The board's Select / Frame / Text tools are NOT one of these, and that is on
//  purpose: they live in the floating action bar, whose vocabulary is 30×28 glyphs and
//  whose active marker is a raised fill. ``SelectionBarModeButton`` is where a MODE row
//  wearing that vocabulary lives. Putting this control in there instead would have been
//  the drift — an outline marker on a bar that marks everything else with a fill.
//
//  Naming follows the existing precedent: `*Chrome()` for a container recipe applied to
//  a view (``popoverChrome()``, ``selectionBarChrome()``), a `ButtonStyle` for a button.
//

import AppKit
import SwiftUI

// MARK: - Field

extension View {
    /// The app's ONE text-field look: unfilled, on a `hairlineStrong` border.
    ///
    /// Apply to a `TextField` that has already been given `.textFieldStyle(.plain)` —
    /// this replaces `.roundedBorder`, whose bezel is drawn by AppKit and cannot be
    /// tokenised.
    ///
    /// The height is a FRAME rather than vertical padding on purpose. Padding sits
    /// outside the field's own rect, so a click in it would miss the text and fail to
    /// focus; a frame stretches the field itself, making the full height hittable. Only
    /// the two `md` horizontal insets are inert. It is a MINIMUM so the field still
    /// grows with Dynamic Type — a fixed height would clip at accessibility sizes.
    func dialogFieldChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        return self
            .font(Theme.Typography.row)
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 32)
            .overlay(shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
    }
}

// MARK: - Segmented control

/// The app's segmented picker — the token-built replacement for
/// `.pickerStyle(.segmented)`, whose AppKit bezel cannot be tokenised.
///
/// Generic over its label so one control covers text ("PDF" / "PNG"), numbers (a
/// contact sheet's 3–6 columns) and SF Symbols (the element inspector's alignment
/// row). There is no container capsule: the segments sit directly on the popover's
/// `surface`, separated by `sm`, and the current one is the one wearing a border.
struct SegmentedControl<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let values: [Value]
    /// Per-segment tooltip. Empty (the default) shows none.
    var help: (Value) -> String = { _ in "" }
    /// Divide the available width equally between the segments instead of letting each
    /// hug its label. For a row of many or long options — the element inspector's four
    /// text weights — where hugging would overflow the card. This is what
    /// `.pickerStyle(.segmented)` did for those rows before.
    var fillsWidth = false
    @ViewBuilder let label: (Value) -> Label

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(values, id: \.self) { value in
                Segment(
                    value: value, selection: $selection, help: help(value),
                    fillsWidth: fillsWidth, label: { label(value) })
            }
        }
        .animation(Theme.Motion.gentle, value: selection)
    }

    /// One segment. The selected one takes the border and `inkPrimary`; an unselected
    /// one stays borderless in `inkSecondary` and picks up the shared `hoverRow` fill,
    /// so both give pointer feedback rather than only the live one.
    private struct Segment<SegmentLabel: View>: View {
        let value: Value
        @Binding var selection: Value
        let help: String
        let fillsWidth: Bool
        @ViewBuilder let label: () -> SegmentLabel

        @State private var isHovering = false

        var body: some View {
            let isSelected = selection == value
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            return Button { selection = value } label: {
                label()
                    .font(Theme.Typography.body).fontWeight(.medium)
                    .foregroundStyle(isSelected ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    // `sm`, not `md`: at `md` a two-segment row of the longest labels
                    // the app has ("Single Page" / "Letter Pages") overflowed its 280pt
                    // card beside a "Layout" label and truncated. The reference frame
                    // shows both in full at that width, so the inset is what gives.
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 6)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
                    .background(shape.fill(!isSelected && isHovering ? Theme.Colors.hoverRow : .clear))
                    .overlay(shape.strokeBorder(
                        isSelected ? Theme.Colors.hairlineStrong : .clear, lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(help)
        }
    }
}

// MARK: - Button

/// The outlined action button a popover ends with — and the inline variant its smaller
/// affordances use.
///
/// Replaces the default push button, whose accent fill would be the app's only coloured
/// chrome (`Theme`'s header: "there is NO coloured accent"). `.keyboardShortcut` is
/// unaffected by a button style, so the Return-to-commit path is unchanged.
struct DialogButtonStyle: ButtonStyle {
    enum Width {
        /// The dialog's primary action: full width, pinned at the bottom of the card.
        case fill
        /// An inline action that hugs its label — the toast's Undo, the gap popover's
        /// two axes, the inspector's Done / Delete.
        case hug
    }

    var width: Width = .fill

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, width: width)
    }

    /// A nested view rather than a bare `configuration.label`: a `ButtonStyle` cannot
    /// read `@Environment(\.isEnabled)` in `makeBody`, and the disabled state has to
    /// dim explicitly — `.plain`-family styles drop the system's own dimming.
    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let width: Width

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            return configuration.label
                .font(width == .fill ? Theme.Typography.row : Theme.Typography.body)
                .fontWeight(width == .fill ? .regular : .medium)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, width == .fill ? Theme.Spacing.sm : 5)
                .frame(maxWidth: width == .fill ? .infinity : nil)
                .background(shape.fill(isHovering && isEnabled ? Theme.Colors.hoverControl : .clear))
                .overlay(shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
                .contentShape(shape)
                // The dimmed-not-hidden idiom the board's floating bar already uses.
                .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.35))
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Labelled row

/// A popover's settings row: label left in `inkSecondary`, control right. The
/// token-built stand-in for `LabeledContent`, whose spacing and type come from the
/// system form metrics rather than the app's scale. Mirrors the detail sidebar's
/// `DetailRow` idiom one layer up.
struct DialogRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(label)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Colors.inkSecondary)
            Spacer(minLength: Theme.Spacing.md)
            content
        }
    }
}

/// ``DialogRow``'s vertical sibling: the same label, stacked ABOVE a control that needs
/// the card's full width. For a row of many or long segments, where label-left would
/// leave the control too little room to show its options.
struct DialogStack<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkSecondary)
            content
        }
    }
}

// MARK: - Colour swatch

/// A bare colour swatch that opens the system colour panel — the Add Color form's
/// picker, and the only control here that AppKit has to supply.
///
/// SwiftUI's `ColorPicker` draws a fixed-size well with its own chrome and cannot be
/// sized or bordered, so it can't wear the tokens. `NSColorWell`'s `.minimal` style is
/// exactly the swatch the reference shows, and takes the frame it is given. Bridging
/// AppKit for a control SwiftUI can't express follows ``VisualEffectBackground``.
struct ColorSwatchWell: NSViewRepresentable {
    @Binding var color: Color

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: .zero)
        well.colorWellStyle = .minimal
        well.supportsAlpha = false
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.color = $color
        // Guarded: assigning `color` re-enters the action on some paths, and an
        // unconditional write would fight the user's drag in the colour panel.
        let target = NSColor(color)
        if well.color != target { well.color = target }
    }

    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

    final class Coordinator: NSObject {
        var color: Binding<Color>

        init(color: Binding<Color>) { self.color = color }

        @objc func colorChanged(_ sender: NSColorWell) {
            color.wrappedValue = Color(nsColor: sender.color)
        }
    }
}
