//
//  SpaceFormatChrome.swift
//  AtelierRefs
//
//  062 — the floating format chrome for a text box, ported from Nook: a one-click
//  colour palette above the box and a font/size bubble below it. Both are FIXED
//  SCREEN SIZE — they sit at a constant 30pt tall however far the canvas is zoomed,
//  because they are chrome, not content (the same split 060 draws between world
//  layout and screen rasterization).
//
//  Where it lives is the one real departure from Nook. Nook draws both panels into
//  its canvas `NSView` and routes clicks by hit-testing rects in `mouseDown`; ours
//  are SwiftUI over the renderer, because `CanvasRenderer` has no business knowing
//  what an `ElementStyle` is — the same seam the inline editor already respects.
//  What Nook keeps and we keep with it is the GEOMETRY: palette above, bubble below,
//  each flipping to the other side at a viewport edge and never landing on top of
//  the other. That math is pure (``SpaceTextChromeLayout``) and unit-tested.
//
//  The panels track the box imperatively through ``SpaceTextChromeAnchor``, off the
//  `SpaceView` body diff (the editor's D6 · R15 posture): a pan, zoom, move or
//  resize republishes ONE `CGRect` and re-renders only these two small views.
//

import AppKit
import AtelierCore
import CanvasRenderer
import Combine
import SwiftUI

// MARK: - Palette

/// The eleven one-click text colours (Nook's `EaselColor`, as our hex strings).
///
/// A fixed palette rather than a colour well is the point of the feature: recolouring
/// is one click on a board, not a trip through the system picker. The full-fidelity
/// `ColorPicker` stays in ``ElementInspector`` for anything off-palette.
enum TextPalette {
    /// A named swatch. The hex is stored verbatim in ``ElementStyle/textColor``.
    struct Swatch: Identifiable, Equatable {
        let name: String
        let hex: String
        var id: String { hex }
        var color: Color {
            Color(rgba: ElementRendering.rgba(fromHex: hex) ?? RGBAColor(red: 0, green: 0, blue: 0))
        }
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Black", hex: "#000000"),
        Swatch(name: "Grey", hex: "#8E8E93"),
        Swatch(name: "White", hex: "#FFFFFF"),
        Swatch(name: "Pink", hex: "#FF7AB6"),
        Swatch(name: "Red", hex: "#FF5A5F"),
        Swatch(name: "Yellow", hex: "#FFCC00"),
        Swatch(name: "Light green", hex: "#7ED957"),
        Swatch(name: "Green", hex: "#34A853"),
        Swatch(name: "Light blue", hex: "#5AC8FA"),
        Swatch(name: "Blue", hex: "#0A84FF"),
        Swatch(name: "Purple", hex: "#AF52DE"),
    ]

    /// Whether a stored `textColor` is this swatch — compared on the PARSED colour,
    /// not the string, so `#ff5a5f`, `#FF5A5F` and `#FF5A5FFF` all read as the same
    /// swatch (they are the same colour, and the inspector's `ColorPicker` writes
    /// whichever form the resolved `NSColor` produces).
    static func matches(_ swatch: Swatch, storedHex: String?) -> Bool {
        guard let stored = ElementRendering.rgba(fromHex: storedHex),
              let mine = ElementRendering.rgba(fromHex: swatch.hex) else { return false }
        // Half a channel step: absorbs the float noise of a hex → RGBA → hex
        // round-trip without ever merging two colours that differ by a real step.
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 / 255 }
        return near(stored.red, mine.red) && near(stored.green, mine.green)
            && near(stored.blue, mine.blue) && near(stored.alpha, mine.alpha)
    }

    /// The swatch a stored colour corresponds to, or `nil` when it is off-palette
    /// (set through the inspector) — which draws no selection ring rather than a
    /// wrong one.
    static func swatch(forStoredHex hex: String?) -> Swatch? {
        swatches.first { matches($0, storedHex: hex) }
    }
}

// MARK: - Layout (pure)

/// Where the two panels sit, in the canvas overlay's coordinate space (top-left
/// origin, y down — the space ``CanvasHostView/screenFrame(forTileID:)`` reports in).
///
/// Pure arithmetic, no views: the flip-at-the-edge and don't-collide rules are the
/// part that is easy to get subtly wrong, so they are tested directly.
enum SpaceTextChromeLayout {
    /// Distance from the box to a panel, and from a panel to the other panel.
    static let gap: CGFloat = 10
    /// Closest a panel may come to the viewport edge.
    static let margin: CGFloat = 4

    static let swatchSize: CGFloat = 16
    static let swatchGap: CGFloat = 6
    static let panelPadding: CGFloat = 8
    static let bubbleHeight: CGFloat = 30
    static let segmentHeight: CGFloat = 22
    static let aaWidth: CGFloat = 30
    static let segmentGap: CGFloat = 8

    /// The palette strip's size — eleven swatches in a row, so it is constant.
    static var paletteSize: CGSize {
        let n = CGFloat(TextPalette.swatches.count)
        return CGSize(
            width: panelPadding * 2 + n * swatchSize + (n - 1) * swatchGap,
            height: panelPadding * 2 + swatchSize)
    }

    /// The size segment's width for a given label — wide enough for "144", never
    /// narrower than a tap target.
    static func sizeSegmentWidth(label: String) -> CGFloat {
        let measured = (label as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return max(26, ceil(measured) + 16)
    }

    /// The bubble's size for a given point-size label.
    static func bubbleSize(sizeLabel: String) -> CGSize {
        CGSize(
            width: panelPadding * 2 + aaWidth + segmentGap + sizeSegmentWidth(label: sizeLabel),
            height: bubbleHeight)
    }

    /// Keep a panel of `width` horizontally on-screen, centred on the box.
    private static func clampedX(anchor: CGRect, width: CGFloat, bounds: CGSize) -> CGFloat {
        let centred = anchor.midX - width / 2
        return max(margin, min(centred, bounds.width - width - margin))
    }

    /// The palette floats ABOVE the box, and flips below when there is no room.
    static func paletteOrigin(anchor: CGRect, size: CGSize, bounds: CGSize) -> CGPoint {
        var y = anchor.minY - size.height - gap
        if y < margin { y = anchor.maxY + gap }
        return CGPoint(x: clampedX(anchor: anchor, width: size.width, bounds: bounds), y: y)
    }

    /// The bubble floats BELOW the box, flips above when there is no room, and in
    /// both directions steps past the palette if the palette had to flip to the same
    /// side. Without that second rule the two panels stack on top of each other at a
    /// viewport edge — the one arrangement where a floating control is unusable.
    static func bubbleOrigin(
        anchor: CGRect, size: CGSize, bounds: CGSize, palette: CGRect?
    ) -> CGPoint {
        var y = anchor.maxY + gap
        if let palette, palette.minY >= anchor.maxY { y = max(y, palette.maxY + gap) }
        if y + size.height > bounds.height - margin {
            y = anchor.minY - size.height - gap
            if let palette, palette.maxY <= anchor.minY { y = min(y, palette.minY - size.height - gap) }
        }
        return CGPoint(x: clampedX(anchor: anchor, width: size.width, bounds: bounds), y: y)
    }

    /// The preset point sizes the bubble's size popover offers (Nook's list).
    static let sizePresets: [CGFloat] = [10, 12, 14, 18, 24, 36, 48, 64, 72, 96, 144]

    /// The label the bubble shows for a style's point size.
    static func sizeLabel(for style: ElementStyle) -> String {
        String(Int((style.fontSize ?? ElementRendering.defaultFontSize).rounded()))
    }
}

// MARK: - Anchor (imperative tracking)

/// The edited / selected box's live on-screen frame, republished whenever it moves.
///
/// This exists so the chrome can follow a pan, zoom, move or resize WITHOUT
/// re-evaluating `SpaceView.body` — the same reason the inline editor repositions
/// imperatively (054 D6 · R15). `SpaceView` owns one, points it at a tile, and pokes
/// ``refresh()`` from the renderer's geometry notifications; only the two small panel
/// views observe it.
@MainActor
final class SpaceTextChromeAnchor: ObservableObject {
    /// The tracked tile's frame in the canvas overlay's coordinates, or `nil` when
    /// nothing is tracked / the tile is off-screen (which hides the chrome).
    @Published private(set) var screenFrame: CGRect?

    private var tileID: Int?
    private weak var bridge: CanvasEditingBridge?

    /// Point the anchor at a tile (or `nil` to stop tracking) and read its frame now.
    func track(tileID: Int?, bridge: CanvasEditingBridge) {
        self.tileID = tileID
        self.bridge = bridge
        refresh()
    }

    /// Re-read the tracked tile's frame. Publishes only on a real change, so the
    /// per-tick notifications a drag or zoom produces cost one `CGRect` compare when
    /// nothing moved.
    func refresh() {
        let frame = tileID.flatMap { bridge?.screenFrame(forTileID: $0) }
        if frame != screenFrame { screenFrame = frame }
    }
}

// MARK: - The chrome

/// The palette + bubble over the canvas, for ONE text box.
struct SpaceFormatChrome: View {
    @ObservedObject var anchor: SpaceTextChromeAnchor
    /// The target's current style — seeds every control (checkmark, ring, label).
    let style: ElementStyle
    /// Apply an edited style. `SpaceView` routes this to `SpaceModel.updateStyle`,
    /// so one click is one undo step with the auto-size folded in (054 §4.3 · D5).
    let onChange: (ElementStyle) -> Void

    @State private var showFont = false
    @State private var showSize = false

    var body: some View {
        GeometryReader { geo in
            if let box = anchor.screenFrame {
                let paletteSize = SpaceTextChromeLayout.paletteSize
                let bubbleSize = SpaceTextChromeLayout.bubbleSize(
                    sizeLabel: SpaceTextChromeLayout.sizeLabel(for: style))
                let palette = CGRect(
                    origin: SpaceTextChromeLayout.paletteOrigin(
                        anchor: box, size: paletteSize, bounds: geo.size),
                    size: paletteSize)
                let bubble = CGRect(
                    origin: SpaceTextChromeLayout.bubbleOrigin(
                        anchor: box, size: bubbleSize, bounds: geo.size, palette: palette),
                    size: bubbleSize)

                paletteBar
                    .frame(width: palette.width, height: palette.height)
                    .position(x: palette.midX, y: palette.midY)

                bubbleBar
                    .frame(width: bubble.width, height: bubble.height)
                    .position(x: bubble.midX, y: bubble.midY)
            }
        }
    }

    // MARK: Palette

    private var paletteBar: some View {
        HStack(spacing: SpaceTextChromeLayout.swatchGap) {
            ForEach(TextPalette.swatches) { swatch in
                SwatchDot(
                    swatch: swatch,
                    isCurrent: TextPalette.matches(swatch, storedHex: style.textColor),
                    action: { change { $0.textColor = swatch.hex } })
            }
        }
        .padding(SpaceTextChromeLayout.panelPadding)
        .panelChrome(cornerRadius: SpaceTextChromeLayout.paletteSize.height / 2)
    }

    // MARK: Bubble

    private var bubbleBar: some View {
        HStack(spacing: SpaceTextChromeLayout.segmentGap) {
            Button { showFont = true } label: {
                Text("Aa")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: SpaceTextChromeLayout.aaWidth,
                           height: SpaceTextChromeLayout.segmentHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Font, weight, and alignment")
            .popover(isPresented: $showFont, arrowEdge: .bottom) {
                SpaceTextFontPopover(style: style, onChange: onChange)
            }

            Divider().frame(height: SpaceTextChromeLayout.segmentHeight - 6)

            Button { showSize = true } label: {
                Text(SpaceTextChromeLayout.sizeLabel(for: style))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(
                        width: SpaceTextChromeLayout.sizeSegmentWidth(
                            label: SpaceTextChromeLayout.sizeLabel(for: style)),
                        height: SpaceTextChromeLayout.segmentHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text size")
            .popover(isPresented: $showSize, arrowEdge: .bottom) {
                SpaceTextSizePopover(
                    current: CGFloat(style.fontSize ?? ElementRendering.defaultFontSize),
                    onSelect: { size in change { $0.fontSize = Double(size) } })
            }
        }
        .padding(.horizontal, SpaceTextChromeLayout.panelPadding)
        .foregroundStyle(Theme.Colors.inkPrimary)
        .panelChrome(cornerRadius: SpaceTextChromeLayout.bubbleHeight / 2)
    }

    /// Edit a copy of the target's style and hand it back — every control's one path
    /// to the model.
    private func change(_ mutate: (inout ElementStyle) -> Void) {
        var edited = style
        mutate(&edited)
        guard edited != style else { return }
        onChange(edited)
    }
}

/// One palette dot: filled circle, hairline ring, thicker label-coloured ring when
/// it is the box's current colour, and a hover ring outside it (Nook's affordance).
private struct SwatchDot: View {
    let swatch: TextPalette.Swatch
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(swatch.color)
                .frame(width: SpaceTextChromeLayout.swatchSize,
                       height: SpaceTextChromeLayout.swatchSize)
                .overlay(
                    Circle().strokeBorder(
                        isCurrent ? Theme.Colors.inkPrimary : Theme.Colors.hairlineStrong,
                        lineWidth: isCurrent ? 2 : 1))
                .overlay(
                    Circle()
                        .strokeBorder(Theme.Colors.inkPrimary.opacity(hovering ? 0.5 : 0), lineWidth: 1.5)
                        .padding(-2.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Popovers

/// The "Aa" popover: family, weight, alignment.
///
/// Nook's is Bold / Italic / Underline + a button to the native Fonts panel, because
/// its text style carries those traits. Ours carries a four-step ``TextWeight`` and a
/// ``TextAlign`` instead (054 §1.1), so the same three-controls-and-a-font-list shape
/// is expressed in the vocabulary our model actually stores.
struct SpaceTextFontPopover: View {
    let style: ElementStyle
    let onChange: (ElementStyle) -> Void

    /// The full system family list, "System" (the nil default) pinned first —
    /// matching ``ElementInspector``.
    private let families = NSFontManager.shared.availableFontFamilies
    private static let systemFamily = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Font", selection: binding(
                get: { style.fontFamily ?? Self.systemFamily },
                set: { $0.fontFamily = $1.isEmpty ? nil : $1 })) {
                Text("System").tag(Self.systemFamily)
                Divider()
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()

            Picker("Weight", selection: binding(
                get: { style.weight },
                set: { $0.fontWeight = $1.rawValue })) {
                ForEach(TextWeight.allCases, id: \.self) { weight in
                    Text(weight.rawValue.capitalized).tag(weight)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Align", selection: binding(
                get: { style.align },
                set: { $0.textAlign = $1.rawValue })) {
                ForEach(TextAlign.allCases, id: \.self) { align in
                    Image(systemName: align.symbolName).tag(align)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        // Popovers get no inset of their own, so the controls sit against the chrome
        // unless the content supplies one. `lg` matches the inspector's, so the two
        // ways into the same settings are padded alike.
        .padding(Theme.Spacing.lg)
        .frame(width: 260)
    }

    /// A `Binding` that reads the current style and writes an edited copy back —
    /// the popover holds no state of its own, so it can't drift from the model.
    private func binding<T: Equatable>(
        get: @escaping () -> T, set: @escaping (inout ElementStyle, T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                guard newValue != get() else { return }
                var edited = style
                set(&edited, newValue)
                onChange(edited)
            })
    }
}

/// The size popover: the presets, with a check on the current one.
struct SpaceTextSizePopover: View {
    let current: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(SpaceTextChromeLayout.sizePresets, id: \.self) { size in
                    Button { onSelect(size) } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("\(Int(size))").font(.system(size: 13)).monospacedDigit()
                            Spacer(minLength: 0)
                            if Int(size.rounded()) == Int(current.rounded()) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // Inset on the rows rather than the scroll view: the row is the click
            // target, so padding it keeps the whole width clickable.
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .frame(width: 124, height: 260)
    }
}

// MARK: - Shared chrome

private extension View {
    /// The floating-panel look, sharing the action bar's tokens so the board's three
    /// floating controls read as one system rather than three ports.
    func panelChrome(cornerRadius: CGFloat) -> some View {
        background(Theme.Colors.field, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }
}
