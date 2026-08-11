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
    private var pill: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ColorDot(hex: share.representativeHex)
            Text(share.bucket.displayName)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs + 2)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip)
            ZStack {
                shape.fill(Theme.Colors.field)
                if isHovering { shape.fill(Theme.Colors.hoverControl) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
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
