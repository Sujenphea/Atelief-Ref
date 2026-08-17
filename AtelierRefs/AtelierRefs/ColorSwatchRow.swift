//
//  ColorSwatchRow.swift
//  AtelierRefs
//
//  085 · C2 — the item detail page's dominant-color row, and the shared swatch dot
//  the search field's color token draws too.
//
//  The analyzer has been storing dominant colors since schema v7 and nothing has
//  ever read them. This is the surface that does. Each chip is one PALETTE BUCKET
//  (`ColorPalette.bucketCoverages` merges the swatches that file together), painted
//  with the most dominant swatch that landed there — the image's own color, not the
//  palette's reference one, so two photographs of red things do not show the
//  identical red.
//
//  Clicking a chip filters. A swatch you cannot act on is the dead end 012's
//  sparkle chips already are, so the row is a row of BUTTONS wherever a host can
//  route a search — which is every pane, since `LibrarySearchable` wraps them all.
//  A Space board has no search field, so it passes no handler and the chips are
//  inert readouts.
//

import AtelierIngestion
import AtelierTokens
import SwiftUI

// MARK: - The shared dot

/// A filled circle in an arbitrary hex, ringed with a hairline.
///
/// The ring is not decoration: the palette's neutrals include `#ffffff` and
/// `#000000`, and either one disappears into the surface it sits on in one of the
/// two themes. A bordered dot reads as a swatch at every lightness.
struct ColorDot: View {
    let hex: String
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color(hexString: hex) ?? Theme.Colors.field)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

// MARK: - The shared chip face

/// A swatch and a name in the app's standard chip: ``DetailChip``'s metrics — `sm`
/// item spacing, `sm` horizontal and `xs + 2` vertical padding, ``Theme/Radius/chip``,
/// a `field` fill that lifts to `hoverControl` — with the dot in the sparkle's place.
///
/// **One face, two chips.** The detail row's chip (085 · C2) and the toolbar
/// palette's (C3) draw exactly this and differ only in what they mean by it: the
/// detail chip is painted with the IMAGE's hex and carries a coverage tooltip, the
/// picker's with the BUCKET's reference hex and a selected state. Those differences
/// live in the two wrappers. Sharing the face is what keeps them one shape — written
/// twice, they had already drifted to different padding and a different dot size
/// before anyone looked at them side by side.
struct ColorChipFace: View {
    let hex: String
    let name: String
    /// Marked as an active filter (the picker). The detail chip never sets it — a
    /// swatch there describes the picture rather than the query.
    var isSelected = false
    var isHovering = false
    /// Stretch to the container's width. The picker's grid needs every chip to fill
    /// its column so the columns line up; the detail row's flow layout needs each to
    /// hug its own text. Explicit rather than a `Spacer` that happens to behave in
    /// both — the two layouts propose width differently.
    var fillsWidth = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ColorDot(hex: hex)
            Text(name)
                .font(Theme.Typography.label)
                .foregroundStyle(isSelected
                    ? Theme.Colors.inkPrimary : Theme.Colors.inkSecondary)
                .lineLimit(1)
            if fillsWidth { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs + 2)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip)
            ZStack {
                shape.fill(isSelected ? Theme.Colors.selection : Theme.Colors.field)
                if isHovering, !isSelected { shape.fill(Theme.Colors.hoverControl) }
            }
        }
        // The one departure from ``DetailChip``, carried from C2: a chip whose
        // content IS a color needs an edge of its own, or the dot's hairline ring
        // reads as the chip's border and a `#ffffff` swatch dissolves into the fill.
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        // The whole pill is the target, not just the dot and the word.
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }
}

// MARK: - The detail section

/// "Colors" — the item's dominant palette, each chip a filter (085 · C2). Renders
/// nothing at all when the asset has no derived colors, so an un-analyzed item, a
/// video, or a color-kind asset simply has no section rather than an empty one.
struct ColorsSection: View {
    let colors: [ColorPalette.BucketCoverage]
    /// Run the filter for a bucket. `nil` on a host with no search field (a Space
    /// board), which makes the chips inert readouts rather than dead buttons.
    let onSelect: ((ColorBucket) -> Void)?

    var body: some View {
        if !colors.isEmpty {
            DetailSection("Colors") {
                TagFlowLayout(spacing: Theme.Spacing.sm) {
                    ForEach(colors, id: \.bucket) { share in
                        ColorSwatchChip(share: share, onSelect: onSelect)
                    }
                }
            }
        }
    }
}

/// One bucket as a chip: the image's own swatch, the bucket's name, and its share
/// of the picture. A button when the host can filter, a plain pill when it cannot.
private struct ColorSwatchChip: View {
    let share: ColorPalette.BucketCoverage
    let onSelect: ((ColorBucket) -> Void)?

    @State private var isHovering = false

    var body: some View {
        if let onSelect {
            Button { onSelect(share.bucket) } label: { pill }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                // The name AND the number, because the chip's color is the
                // picture's and its filter is the bucket's — the tooltip is where
                // that difference is stated rather than left to be discovered.
                .help("Find \(share.bucket.displayName.lowercased()) items · \(percentage) of this image")
                .accessibilityLabel("\(share.bucket.displayName), \(percentage)")
                .accessibilityHint("Filters the library by this color")
        } else {
            pill
                .help("\(share.bucket.displayName) · \(percentage) of this image")
                .accessibilityLabel("\(share.bucket.displayName), \(percentage)")
        }
    }

    /// Dot + name, exactly the shape ``DetailChip`` gives the Tags and Collections
    /// rows above it — the swatch takes the ✦'s place. The coverage stays in the
    /// tooltip: the row is already ordered by it, and a second number on every chip
    /// crowds a 298pt sidebar column for something nobody reads at a glance.
    ///
    /// Hugs its text rather than filling — the row is a ``TagFlowLayout``, which
    /// packs chips at their own widths.
    private var pill: some View {
        ColorChipFace(
            hex: share.representativeHex,
            name: share.bucket.displayName,
            isHovering: isHovering)
    }

    /// The bucket's share of the image, whole percent.
    ///
    /// Rounded UP off zero: a swatch that survived extraction covers something, and
    /// "0%" next to a visible color reads as a bug. The default coverage floor is
    /// 15%, so nothing here is precise enough to deserve a decimal.
    private var percentage: String {
        let percent = share.coverage * 100
        return "\(max(1, Int(percent.rounded())))%"
    }
}
