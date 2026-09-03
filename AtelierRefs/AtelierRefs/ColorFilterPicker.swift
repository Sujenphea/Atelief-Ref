//
//  ColorFilterPicker.swift
//  AtelierRefs
//
//  085 · C3 — the toolbar palette: the way a color filter is STARTED, rather than
//  only continued from a picture that already has one.
//
//  Every other filter dimension can be typed. A tag or a collection prefix-matches
//  in the suggestion dropdown and becomes a token. A color cannot: a swatch has no
//  text, `refreshSuggestions` only ever fetches tags and collections, and nothing
//  resolves the word "teal" to a bucket. Until this existed the only way to make a
//  `.color` token was to already be looking at a picture that had that color
//  (085 · C2) — which is a filter you can only reach from an answer, never from a
//  question.
//
//  So the picker shows the whole palette instead of asking anyone to recall it, and
//  each chip toggles the SAME token the detail row and the search field use. One
//  piece of state, three views of it — the rule `FavoritesFilterChip` already
//  follows.
//
//  **099 · P10 — the Any / All control, and the chord that reaches it.** 085 left
//  one thing open and then closed it in prose: colours combine with `TagMatch`, the
//  answer is `.any`, "`.all` is reachable through the API and has tests; no UI
//  offers it yet". Four docs later that was still true — `searchAssets` took
//  `colorMatch`, `SearchRules` stored it, the SQL switched on it, and the only way
//  to say `.all` was to hand-write a rules blob. The control lives HERE, next to the
//  chips it governs, and appears only once two chips are on, because below two the
//  two modes select the same pictures. And the picker gains ⇧⌘C, which is the first
//  keyboard route this surface has ever had: without it the Any / All control is
//  behind a mouse-only popover, which is most of the way back to having no UI.
//
//  **The colour wheel is still out, and that is 085's call, not an omission.** Its
//  risks section says a wheel "needs real Lab coordinates per swatch" and the v21
//  table stores a palette bucket INTEGER and a coverage — an integer a wheel cannot
//  be drawn from. Adding `l, a, b` columns is additive and the pass that would fill
//  them already exists, so the door is open; opening it is a schema change and a
//  re-derivation, which is a phase, not a control.
//

import AtelierCore
import AtelierIngestion
import SwiftUI

// MARK: - The toolbar button

/// The toolbar's color filter (085 · C3): a palette glyph that opens the twelve
/// buckets, filled while any of them is on.
///
/// Present on EVERY searchable pane, unlike ``FavoritesFilterChip``, which the
/// collection screens keep to themselves. The argument for hiding that one — "the
/// filter is reached by the token like any other, and a second home would compete"
/// — does not transfer, because there is no first home: without this button a
/// color filter has no route in at all on Home, Capture, Shelf or a Space board.
struct ColorFilterPicker: View {
    @ObservedObject var search: LibrarySearchModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: search.hasColorFilter ? "paintpalette.fill" : "paintpalette")
                .font(.system(size: 14))
                .foregroundStyle(search.hasColorFilter
                    ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
        }
        // The toolbar tier, which owns the geometry — see the style for why a
        // toolbar item cannot use the plain ``HoverButtonStyle``.
        .buttonStyle(ToolbarGlyphButtonStyle())
        .help(helpText)
        .accessibilityLabel("Color filter")
        .accessibilityAddTraits(search.hasColorFilter ? [.isSelected] : [])
        // ⇧⌘C — 099 · P10, and recorded in `KeyMap` as a `.global` row for the
        // reason ⌘S's row gives: a `ToolbarItem` hangs off the scene, not off the
        // field, so its chord fires wherever the keyboard is.
        //
        // **Shifted, because ⌘C is Copy.** Plain ⌘C is bound in `.collection` and
        // on a Space board, and a `.global` row would be matched BEFORE either of
        // them — the collision test would have said so, and the answer would have
        // been to break copy-paste. ⇧⌘C is claimed by no row in any scope and is
        // the letter of the thing it opens.
        .keyboardShortcut("c", modifiers: [.command, .shift])
        // A popover rather than the suggestion dropdown's floated card: this one is
        // hung off a toolbar BUTTON with nothing to type into, so it can take first
        // responder freely — the reason the suggestion list cannot be one.
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ColorFilterPalette(search: search)
        }
    }

    /// Names the colors that are on, so the tooltip answers "filtered by what?"
    /// without opening the popover. The chips in the field say the same thing, but
    /// they scroll out of a narrow field and this does not.
    ///
    /// The joiner is the MODE (099 · P10): "Red or Blue" and "Red and Blue" are
    /// two different filters and the tooltip is the only place outside the open
    /// popover that can tell them apart — the chips in the field cannot, because
    /// they are one chip each.
    private var helpText: String {
        let selected = search.selectedColorBuckets
        guard !selected.isEmpty else { return "Filter by color" }
        let joiner = search.colorMatch == .all ? " and " : " or "
        return "Filtering by \(selected.map(\.displayName).joined(separator: joiner))"
    }
}

// MARK: - The palette

/// The twelve buckets as toggle chips, in ``ColorPalette/filterOrder`` — neutrals
/// first, then the wheel.
///
/// A grid rather than a list: twelve rows would be a scroller, and the whole reason
/// this surface exists is that colors are recognized at a glance rather than read.
private struct ColorFilterPalette: View {
    @ObservedObject var search: LibrarySearchModel

    /// Three columns × four rows. Fixed rather than adaptive — the popover is given
    /// a width below, so an adaptive grid would have nothing to adapt to.
    private static let columnCount = 3
    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.xs), count: columnCount)

    /// Wide enough for three chips at the app's standard chip metrics.
    ///
    /// The number is derived rather than guessed, because the guess was wrong once:
    /// at 260 the chips only fit by shrinking their dot and padding below every
    /// other chip in the app, which is the layout dictating the component instead of
    /// the other way round. A chip is `sm` + dot + `sm` + text + `sm` ≈ 36pt of
    /// chrome, and the longest bucket name ("Orange", "Yellow", "Purple") measures
    /// about 47pt at ``Theme/Typography/label`` — call it 83pt each, plus the gaps
    /// between columns and the popover's own padding.
    private static let width: CGFloat = {
        let chip: CGFloat = 83
        let gaps = Theme.Spacing.xs * CGFloat(columnCount - 1)
        return chip * CGFloat(columnCount) + gaps + Theme.Spacing.md * 2
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Color")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkSecondary)

            LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.xs) {
                ForEach(ColorPalette.filterOrder, id: \.self) { bucket in
                    ColorFilterChip(
                        bucket: bucket,
                        isSelected: search.isColorSelected(bucket)
                    ) {
                        search.toggleColorFilter(bucket)
                    }
                }
            }

            // The Any / All control (099 · P10), and only once there are two
            // colours for it to combine: with one chip on, both modes select the
            // same pictures, so the control would be a switch with one position —
            // the same dead affordance the "Clear colors" button below refuses to
            // be. `showsColorMatchControl` owns that rule and is tested; this view
            // only draws it.
            //
            // `DialogRow` + `SegmentedControl` are the app's popover vocabulary
            // (see `DialogControls.swift`), so this row looks like every other
            // labelled choice in the app rather than like a stock AppKit picker.
            if search.showsColorMatchControl {
                Divider()
                DialogRow("Match") {
                    SegmentedControl(
                        selection: $search.colorMatch, values: [.any, .all],
                        help: {
                            $0 == .all
                                ? "Only pictures showing every selected color"
                                : "Pictures showing any of the selected colors"
                        }
                    ) {
                        Text($0 == .all ? "All" : "Any")
                    }
                }
            }

            // Only while there is something to clear — a permanently-visible
            // control that does nothing most of the time is the kind of dead
            // affordance the sub-floor chips of 378 already were.
            if search.hasColorFilter {
                Divider()
                Button("Clear colors") { search.clearColorFilters() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .help("Remove every color filter, leaving the rest of the query")
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: Self.width)
    }
}

/// One bucket as a toggle: its reference swatch and its name, filled while on.
///
/// The swatch is the palette's ``ColorBucket/referenceHex``, NOT an image's color —
/// the opposite of the detail row's chip (085 · C2), and deliberately. This chip
/// says what the BUCKET means, because there is no picture in front of it to mean
/// anything else. Everything else about the two is one ``ColorChipFace``.
private struct ColorFilterChip: View {
    let bucket: ColorBucket
    let isSelected: Bool
    var onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            ColorChipFace(
                hex: bucket.referenceHex,
                name: bucket.displayName,
                isSelected: isSelected,
                isHovering: isHovering,
                // Fills its grid column, so the three columns line up whatever the
                // name's length — "Teal" and "Orange" must not be different widths.
                fillsWidth: true)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isSelected
            ? "Stop filtering by \(bucket.displayName.lowercased())"
            : "Filter by \(bucket.displayName.lowercased())")
        .accessibilityLabel(bucket.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
