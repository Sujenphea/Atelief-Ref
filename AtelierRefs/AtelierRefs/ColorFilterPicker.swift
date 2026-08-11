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
    private var helpText: String {
        let selected = search.selectedColorBuckets
        guard !selected.isEmpty else { return "Filter by color" }
        return "Filtering by \(selected.map(\.displayName).joined(separator: ", "))"
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
