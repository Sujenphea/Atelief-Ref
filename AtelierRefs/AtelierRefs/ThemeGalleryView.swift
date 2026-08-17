//
//  ThemeGalleryView.swift
//  AtelierRefs
//
//  The design system, rendered. `AtelierTokens` holds the values and `Theme.swift`
//  is this app's view of them — but until now there was nowhere
//  to SEE it, which is how `field` and `selection` drifted to within 14 points of
//  each other unnoticed, and how three `NS` mirrors fell out of step with their
//  `Colors` originals (both recorded in `.change-log/295-adopt-or-drop-every-token.md`).
//  A specimen page makes those failures visible in one scroll instead of one screen
//  at a time.
//
//  DEBUG ONLY. It is a maintenance tool for the theme, not a feature: the sidebar
//  row, the `SidebarItem` case and this file's contents all compile out of a release
//  build. It lives in the sidebar rather than behind a launch argument (the
//  `Debug/GridBakeoff*` precedent) for one reason — the tokens have to be judged
//  against the chrome they actually sit in. A separate `NSWindow` would render every
//  swatch on a background that is not the `panel` they are used over, which is
//  exactly the comparison that matters.
//
//  It reads the tokens rather than restating them: hexes are DERIVED from the live
//  `Color` values, and the `NS` mirrors are compared against their originals at
//  render time. A specimen page that hard-coded "#2C2C30" beside `Colors.field`
//  would be a fourth copy of the palette and the next thing to drift.
//

#if DEBUG

import AppKit
import AtelierTokens
import SwiftUI

struct ThemeGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Text("Theme")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.inkPrimary)
                Text("Every token in `AtelierTokens`, drawn. DEBUG builds only.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)

                ColourSpecimens()
                MirrorSpecimens()
                TypeSpecimens()
                ScaleSpecimens()
                ElevationSpecimens()
                ControlSpecimens()
                MotionSpecimens()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.xl)
        }
    }
}

// MARK: - Shared chrome

/// A titled group. Mirrors `DetailSection`'s shape (a `sectionTitle` over its rows)
/// rather than importing it — that one is `private` to `ItemDetailView`, and a
/// specimen page copying the idiom is the point of the page.
private struct GallerySection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    init(_ title: String, _ note: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Typography.bodyEmphasis)
                .foregroundStyle(Theme.Colors.inkPrimary)
            if !note.isEmpty {
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .background(
            Theme.Colors.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.hairline))
    }
}

/// The sRGB description of a live token — `#RRGGBB`, plus the alpha when it carries
/// one. Derived, never transcribed, so this page cannot disagree with `Theme`.
private func hexDescription(_ color: Color) -> String {
    guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "—" }
    return hexDescription(ns)
}

private func hexDescription(_ ns: NSColor) -> String {
    guard let srgb = ns.usingColorSpace(.sRGB) else { return "—" }
    let hex = String(
        format: "#%02X%02X%02X",
        Int((srgb.redComponent * 255).rounded()),
        Int((srgb.greenComponent * 255).rounded()),
        Int((srgb.blueComponent * 255).rounded()))
    guard srgb.alphaComponent < 0.999 else { return hex }
    return "\(hex) · \(Int((srgb.alphaComponent * 100).rounded()))%"
}

// MARK: - Colour

private struct ColourSpecimens: View {
    /// Name → token. Ordered as `Theme.Colors` declares them, so a reader can hold
    /// the two side by side.
    private static let tokens: [(String, Color)] = [
        ("canvasOuter", Theme.Colors.canvasOuter),
        ("panel", Theme.Colors.panel),
        ("surface", Theme.Colors.surface),
        ("field", Theme.Colors.field),
        ("selection", Theme.Colors.selection),
        ("selectionMark", Theme.Colors.selectionMark),
        ("selectionMarkContrast", Theme.Colors.selectionMarkContrast),
        ("mediaBackdrop", Theme.Colors.mediaBackdrop),
        ("inkPrimary", Theme.Colors.inkPrimary),
        ("inkSecondary", Theme.Colors.inkSecondary),
        ("hairline", Theme.Colors.hairline),
        ("hairlineStrong", Theme.Colors.hairlineStrong),
        ("hoverRow", Theme.Colors.hoverRow),
        ("hoverControl", Theme.Colors.hoverControl),
        ("warning", Theme.Colors.warning),
    ]

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: Theme.Spacing.md)]

    var body: some View {
        GallerySection(
            "Colour",
            "Swatches sit on `panel` — the ground most of them are used over. The "
            + "translucent tokens (hairline, hover…) are drawn over it too, so what "
            + "you see is the composited result rather than the raw value."
        ) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Self.tokens, id: \.0) { name, color in
                    swatch(name, color)
                }
            }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Theme.Colors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .fill(color))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(Theme.Colors.hairlineStrong))
                .frame(height: 44)
            Text(name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(hexDescription(color))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
    }
}

// MARK: - AppKit mirrors

/// `Theme.NS` against `Theme.Colors`, compared at render time.
///
/// This is the section the page exists for. A mirror is a second copy of a value
/// that no compiler checks, and three of them had already drifted before anyone
/// noticed. Here a drifted pair reports itself in ``Theme/Colors/warning`` the first
/// time somebody opens the page.
private struct MirrorSpecimens: View {
    private static let pairs: [(String, Color, NSColor)] = [
        ("mediaBackdrop", Theme.Colors.mediaBackdrop, Theme.NS.mediaBackdrop),
        ("selection", Theme.Colors.selection, Theme.NS.selection),
        ("selectionMark", Theme.Colors.selectionMark, Theme.NS.selectionMark),
        ("selectionMarkContrast", Theme.Colors.selectionMarkContrast, Theme.NS.selectionMarkContrast),
        ("inkPrimary", Theme.Colors.inkPrimary, Theme.NS.inkPrimary),
        ("inkSecondary", Theme.Colors.inkSecondary, Theme.NS.inkSecondary),
        ("hairlineStrong", Theme.Colors.hairlineStrong, Theme.NS.hairlineStrong),
        ("hoverRow", Theme.Colors.hoverRow, Theme.NS.hoverRow),
    ]

    var body: some View {
        GallerySection(
            "AppKit mirrors",
            "`Theme.NS` beside `Theme.Colors`. Nothing checks these agree — the "
            + "layer-backed grid, the sidebar outline view and the floating add "
            + "button read the NS side. A mismatch is flagged."
        ) {
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(Self.pairs, id: \.0) { name, swiftUI, appKit in
                    row(name, swiftUI, appKit)
                }
            }
        }
    }

    private func row(_ name: String, _ swiftUI: Color, _ appKit: NSColor) -> some View {
        let matches = hexDescription(swiftUI) == hexDescription(appKit)
        return HStack(spacing: Theme.Spacing.md) {
            Text(name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .frame(width: 180, alignment: .leading)
            chip(Color(nsColor: appKit))
            Text(hexDescription(swiftUI))
                .font(Theme.Typography.caption)
                .foregroundStyle(matches ? Theme.Colors.inkSecondary : Theme.Colors.warning)
            Spacer(minLength: Theme.Spacing.sm)
            if matches {
                Text("matches")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            } else {
                Label("drifted — NS says \(hexDescription(appKit))",
                      systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
    }

    private func chip(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong))
            .frame(width: 28, height: 18)
    }
}

// MARK: - Typography

private struct TypeSpecimens: View {
    private static let roles: [(String, Font, String)] = [
        ("pageTitle", Theme.Typography.pageTitle, "A sheet or overlay title"),
        ("sectionTitle", Theme.Typography.sectionTitle, "A page or section title"),
        ("navItem", Theme.Typography.navItem, "Sidebar top-nav row"),
        ("row", Theme.Typography.row, "Collection rows, chip and field text"),
        ("bodyEmphasis", Theme.Typography.bodyEmphasis, "A card title, a row heading"),
        ("body", Theme.Typography.body, "Running text, descriptions, toasts"),
        ("label", Theme.Typography.label, "Metadata labels and values"),
        ("caption", Theme.Typography.caption, "The smallest text the app draws"),
        ("mono", Theme.Typography.mono, "A token, a hash — 0O 1lI compared"),
    ]

    var body: some View {
        GallerySection(
            "Typography",
            "Nine roles. Each is a text STYLE plus a weight, not a point size, so "
            + "every one of them scales with the Accessibility text-size setting — "
            + "raise it in System Settings and this section should reflow."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Self.roles, id: \.0) { name, font, sample in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                        Text(sample)
                            .font(font)
                            .foregroundStyle(Theme.Colors.inkPrimary)
                    }
                }
            }
        }
    }
}

// MARK: - Spacing + radius

private struct ScaleSpecimens: View {
    private static let spacing: [(String, CGFloat)] = [
        ("xs", Theme.Spacing.xs), ("sm", Theme.Spacing.sm), ("md", Theme.Spacing.md),
        ("lg", Theme.Spacing.lg), ("xl", Theme.Spacing.xl), ("xxl", Theme.Spacing.xxl),
    ]

    private static let radius: [(String, CGFloat)] = [
        ("chip", Theme.Radius.chip), ("field", Theme.Radius.field),
        ("control", Theme.Radius.control), ("tile", Theme.Radius.tile),
        ("card", Theme.Radius.card), ("cover", Theme.Radius.cover),
        ("panel", Theme.Radius.panel),
    ]

    var body: some View {
        GallerySection(
            "Spacing and radius",
            "Drawn to size. `chip` and `field` are deliberately the same value — two "
            + "names for what a call site IS, not two measurements."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(Self.spacing, id: \.0) { name, value in
                    HStack(spacing: Theme.Spacing.md) {
                        Text(name)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                            .frame(width: 40, alignment: .leading)
                        Rectangle()
                            .fill(Theme.Colors.inkSecondary)
                            .frame(width: value, height: 12)
                        Text("\(Int(value))pt")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                    }
                }

                Divider().overlay(Theme.Colors.hairline)

                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    ForEach(Self.radius, id: \.0) { name, value in
                        VStack(spacing: Theme.Spacing.xs) {
                            RoundedRectangle(cornerRadius: value, style: .continuous)
                                .fill(Theme.Colors.field)
                                .overlay(
                                    RoundedRectangle(cornerRadius: value, style: .continuous)
                                        .strokeBorder(Theme.Colors.hairlineStrong))
                                .frame(width: 60, height: 44)
                            Text(name)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.inkPrimary)
                            Text("\(Int(value))")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.inkSecondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Elevation

private struct ElevationSpecimens: View {
    var body: some View {
        GallerySection(
            "Elevation",
            "Two tokens. `hover` is the heavy lift a popover uses to separate itself "
            + "from content it floats over; `floating` is the softer one a bar or pill "
            + "riding over known layout uses."
        ) {
            HStack(spacing: Theme.Spacing.xl) {
                card("hover", .hover)
                card("floating", .floating)
            }
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    private func card(_ name: String, _ elevation: Theme.Elevation) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.surface)
                .frame(width: 120, height: 64)
                .elevation(elevation)
            Text(name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.inkPrimary)
            Text("α\(String(format: "%.2f", elevation.opacity)) · r\(Int(elevation.radius)) · y\(Int(elevation.y))")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
    }
}

// MARK: - Controls

/// Live instances of everything in `DialogControls.swift`, in every state that has
/// its own drawing. Hover them — the feedback fills are tokens too, and they are the
/// part a static screenshot can never show.
private struct ControlSpecimens: View {
    @State private var segment = "PNG"
    @State private var wide = 4
    @State private var text = "Untitled"

    var body: some View {
        GallerySection(
            "Controls",
            "The popover vocabulary: outlined, unfilled, on a `hairlineStrong` border. "
            + "Selection here is an OUTLINE rather than a fill — inside a card that is "
            + "already `surface`, a second raised grey would read as a third layer."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                DialogStack("Segmented — hugging") {
                    SegmentedControl(selection: $segment, values: ["PDF", "PNG", "JPEG"]) {
                        Text($0)
                    }
                }

                DialogStack("Segmented — fills width") {
                    SegmentedControl(selection: $wide, values: [3, 4, 5, 6], fillsWidth: true) {
                        Text("\($0)")
                    }
                }

                DialogRow("Field") {
                    TextField("Name", text: $text)
                        .textFieldStyle(.plain)
                        .dialogFieldChrome()
                }

                DialogRow("Button · hug") {
                    Button("Action") {}.buttonStyle(DialogButtonStyle(width: .hug))
                    Button("Disabled") {}.buttonStyle(DialogButtonStyle(width: .hug)).disabled(true)
                }

                DialogStack("Button · fill") {
                    Button("Primary action") {}.buttonStyle(DialogButtonStyle())
                }

                DialogStack("Popover chrome") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("A popover card").font(Theme.Typography.bodyEmphasis)
                        Text("`surface` on a plain `hairline`, lifted by `hover`.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                    }
                    .padding(Theme.Spacing.lg)
                    .popoverChrome()
                    .frame(width: 280)
                }
            }
        }
    }
}

// MARK: - Motion

/// The three springs, run side by side.
///
/// The only section that needs interacting with: a duration and a damping fraction
/// are unreadable as numbers, and the whole reason `Motion` exists is that the app
/// had five hand-tuned springs nobody could compare. Tap to run all three at once —
/// they are only distinguishable against each other.
private struct MotionSpecimens: View {
    @State private var moved = false

    var body: some View {
        GallerySection(
            "Motion",
            "Tap to run all three together. `snappy` is the app's default state "
            + "change, `gentle` a small cross-fade, `toast` the softest — a thing "
            + "arriving on screen uninvited."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                track("snappy", Theme.Motion.snappy)
                track("gentle", Theme.Motion.gentle)
                track("toast", Theme.Motion.toast)

                Button(moved ? "Send back" : "Run") { moved.toggle() }
                    .buttonStyle(DialogButtonStyle(width: .hug))
            }
        }
    }

    private func track(_ name: String, _ animation: Animation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(name)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .fill(Theme.Colors.field)
                .frame(height: 28)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Theme.Colors.inkPrimary)
                        .frame(width: 18, height: 18)
                        .padding(.leading, 5)
                        .offset(x: moved ? 220 : 0)
                        .animation(animation, value: moved)
                }
        }
    }
}

#endif
