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
    /// Space between swatches in the colour popover's grid. Wider than the hover
    /// ring's overhang so two neighbours' rings never touch.
    static let swatchGap: CGFloat = 10
    static let panelPadding: CGFloat = 8
    static let bubbleHeight: CGFloat = 30
    static let segmentHeight: CGFloat = 22
    static let aaWidth: CGFloat = 30
    /// The colour segment — a single dot showing the box's current colour.
    static let swatchSegmentWidth: CGFloat = 26
    static let segmentGap: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    /// Columns in the colour popover's grid (11 swatches → 6 + 5).
    static let paletteColumns = 6

    /// The size segment's width for a given label — wide enough for "144", never
    /// narrower than a tap target.
    static func sizeSegmentWidth(label: String) -> CGFloat {
        let measured = (label as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return max(26, ceil(measured) + 16)
    }

    /// The "Aa" popover's width, MEASURED rather than guessed.
    ///
    /// Its widest control is the four-way weight picker, and a segmented control does
    /// not grow to fit — it compresses and clips, so "Semibold" becomes "Semib…" at a
    /// width that looked fine for "Bold". Deriving it from the labels means it still
    /// fits if a weight is renamed or the system font size changes.
    static var fontPopoverWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = TextWeight.allCases
            .map { ($0.rawValue.capitalized as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let segment = ceil(widest) + 20 // the control's own per-segment padding
        return max(260, segment * CGFloat(TextWeight.allCases.count) + 2 * Theme.Spacing.lg)
    }

    /// The bubble's size for a given point-size label: `Aa | size | ●`, with the two
    /// dividers and the gaps either side of each counted in — the panel's frame is set
    /// from this number, so anything left out of it is squeezed out of the content.
    static func bubbleSize(sizeLabel: String) -> CGSize {
        let separators = 2 * (segmentGap + dividerWidth + segmentGap)
        return CGSize(
            width: panelPadding * 2 + aaWidth + sizeSegmentWidth(label: sizeLabel)
                + swatchSegmentWidth + separators,
            height: bubbleHeight)
    }

    /// Keep a panel of `width` horizontally on-screen, centred on the box.
    ///
    /// Rounded to whole points. The box's on-screen frame is fractional at most zoom
    /// levels, and a panel landing on a half point puts its hairline border — and the
    /// rings around its 16pt swatches — across two rows of pixels, which reads as a
    /// blurred, very slightly off-centre dot.
    private static func clampedX(anchor: CGRect, width: CGFloat, bounds: CGSize) -> CGFloat {
        let centred = anchor.midX - width / 2
        return max(margin, min(centred, bounds.width - width - margin)).rounded()
    }

    /// The bubble floats BELOW the box, and flips above when there is no room.
    ///
    /// It used to have a second rule — step past the colour palette when that panel
    /// had flipped to the same side. Collapsing the palette into a single segment took
    /// the second panel away, and the rule with it: there is nothing left to collide
    /// with, so the only edge case is the viewport's own bottom.
    static func bubbleOrigin(anchor: CGRect, size: CGSize, bounds: CGSize) -> CGPoint {
        var y = anchor.maxY + gap
        if y + size.height > bounds.height - margin { y = anchor.minY - size.height - gap }
        return CGPoint(x: clampedX(anchor: anchor, width: size.width, bounds: bounds), y: y.rounded())
    }

    /// The preset point sizes the bubble's size popover offers (Nook's list).
    static let sizePresets: [CGFloat] = [10, 12, 14, 16, 18, 24, 36, 48, 64, 72, 96, 144]

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
    /// The live canvas host, set from `onHostReady`. `weak` so a detached host is never
    /// kept alive by the bubble.
    weak var host: CanvasHostView?

    /// Point the anchor at a tile (or `nil` to stop tracking) and read its frame now.
    func track(tileID: Int?) {
        self.tileID = tileID
        refresh()
    }

    /// Re-read the tracked tile's frame. Publishes only on a real change, so the
    /// per-tick notifications a drag or zoom produces cost one `CGRect` compare when
    /// nothing moved.
    func refresh() {
        let frame = tileID.flatMap { host?.screenFrame(forTileID: $0) }
        if frame != screenFrame { screenFrame = frame }
    }
}

// MARK: - The chrome

/// The bubble over the canvas, for ONE text box: font · size · colour.
struct SpaceFormatChrome: View {
    @ObservedObject var anchor: SpaceTextChromeAnchor
    /// The target's current style — seeds every control (checkmark, ring, label).
    let style: ElementStyle
    /// Whether each popover is open. Bound to `SpaceView` rather than held here: the
    /// chrome is mounted only while a box is being edited, and presenting a popover
    /// can end that edit — so the flag has to outlive this view's own state.
    @Binding var showFont: Bool
    @Binding var showSize: Bool
    @Binding var showColor: Bool
    /// Apply an edited style. `SpaceView` routes this to `SpaceModel.updateStyle`,
    /// so one click is one undo step with the auto-size folded in (054 §4.3 · D5).
    let onChange: (ElementStyle) -> Void

    var body: some View {
        GeometryReader { geo in
            if let box = anchor.screenFrame {
                let size = SpaceTextChromeLayout.bubbleSize(
                    sizeLabel: SpaceTextChromeLayout.sizeLabel(for: style))
                let bubble = CGRect(
                    origin: SpaceTextChromeLayout.bubbleOrigin(
                        anchor: box, size: size, bounds: geo.size),
                    size: size)

                bubbleBar
                    .frame(width: bubble.width, height: bubble.height)
                    .position(x: bubble.midX, y: bubble.midY)
            }
        }
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

            divider

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

            divider

            // The colour segment shows the box's CURRENT colour and opens the eleven.
            // A strip of all of them was the first cut, and it made the chrome twice
            // the size of the thing it formats — 252pt of panel over a box that is
            // often narrower than that.
            Button { showColor = true } label: {
                SwatchDotBody(swatch: currentSwatch, isCurrent: false, hovering: false)
                    .frame(width: SpaceTextChromeLayout.swatchSegmentWidth,
                           height: SpaceTextChromeLayout.segmentHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text colour")
            .popover(isPresented: $showColor, arrowEdge: .bottom) {
                SpaceTextColorPopover(
                    current: style.textColor,
                    onSelect: { hex in change { $0.textColor = hex } })
            }
        }
        .padding(.horizontal, SpaceTextChromeLayout.panelPadding)
        .foregroundStyle(Theme.Colors.inkPrimary)
        .panelChrome(cornerRadius: SpaceTextChromeLayout.bubbleHeight / 2)
    }

    private var divider: some View {
        Divider()
            .frame(width: SpaceTextChromeLayout.dividerWidth,
                   height: SpaceTextChromeLayout.segmentHeight - 6)
    }

    /// The dot the colour segment shows: the matching palette swatch, or — for a
    /// colour set through the inspector's picker — an unnamed swatch of the stored
    /// hex, so the segment always shows the box's real colour rather than a default.
    private var currentSwatch: TextPalette.Swatch {
        TextPalette.swatch(forStoredHex: style.textColor)
            ?? TextPalette.Swatch(
                name: "Custom", hex: style.textColor ?? ElementRendering.defaultTextColorHex)
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
            SwatchDotBody(swatch: swatch, isCurrent: isCurrent, hovering: hovering)
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// The dot's DRAWING, split from its button so a test can render it at a known hover
/// state and measure where the ink actually lands (`SpaceFormatChromeTests`). Two
/// attempts at centring this ring were reported as still off, which is one more than
/// a thing this simple deserves before it gets measured rather than reasoned about.
struct SwatchDotBody: View {
    let swatch: TextPalette.Swatch
    let isCurrent: Bool
    let hovering: Bool

    /// The hover ring's diameter: the dot plus **2pt of clearance on each side**.
    ///
    /// Even, deliberately. An odd ring around an even dot (21 around 16) is concentric
    /// in layout but lands its stroke on half-points, so at 1× it is antialiased
    /// across two pixel rows — heavier on one side than the other, which is exactly
    /// what "not centred" looks like. Kept well inside the 6pt swatch gap so two
    /// neighbours' rings never touch.
    static let hoverRingSize = SpaceTextChromeLayout.swatchSize + 4

    var body: some View {
        ZStack {
            Circle().fill(swatch.color)
            Circle().strokeBorder(
                isCurrent ? Theme.Colors.inkPrimary : Theme.Colors.hairlineStrong,
                lineWidth: isCurrent ? 2 : 1)
        }
        .frame(width: SpaceTextChromeLayout.swatchSize,
               height: SpaceTextChromeLayout.swatchSize)
        // The ring is CENTRED on the dot by an explicit frame rather than grown out of
        // it by a negative padding — an overlay is centred on its base, so concentric
        // is a layout guarantee here rather than the outcome of insetting a frame by
        // equal amounts on four sides. It overflows the dot's 16pt slot on purpose:
        // the panel's own 8pt padding leaves room, and the dot's LAYOUT size stays 16,
        // so the strip is still exactly the width `paletteSize` reports.
        .overlay {
            Circle()
                .strokeBorder(
                    Theme.Colors.inkPrimary.opacity(hovering ? 0.5 : 0), lineWidth: 1.5)
                .frame(width: Self.hoverRingSize, height: Self.hoverRingSize)
        }
        .contentShape(Circle())
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

    /// The system-font sentinel — ``FontFamilyPicker`` owns the list itself now (064).
    private static let systemFamily = FontFamilyCatalog.systemFamily

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            FontFamilyPicker(selection: binding(
                get: { style.fontFamily ?? Self.systemFamily },
                set: { $0.fontFamily = $1.isEmpty ? nil : $1 }))

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

            // Width (063). This control is the whole reason auto-width could come
            // back: 062 rejected the mode because it would be reachable only by
            // gesture — "a hidden consequence of an action rather than a state the
            // user can see". Here it is a state they set, see, and can set back.
            Picker("Width", selection: binding(
                get: { style.hugsWidth },
                set: { $0.textAutoWidth = $1 })) {
                Text("Auto").tag(true)
                Text("Fixed").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        // Popovers get no inset of their own, so the controls sit against the chrome
        // unless the content supplies one. `lg` matches the inspector's, so the two
        // ways into the same settings are padded alike.
        .padding(Theme.Spacing.lg)
        .frame(width: SpaceTextChromeLayout.fontPopoverWidth)
        // A family name longer than the popover truncates the button's label rather
        // than stretching the popover past the width the weight picker needs.
        .lineLimit(1)
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

/// The colour popover: the eleven swatches, one click each.
///
/// Nook floats all eleven permanently above the box. That reads well on its canvas
/// and badly on ours — the strip is 252pt wide, wider than many of the text boxes it
/// would be formatting, so the chrome dwarfed its subject. One dot in the bubble,
/// opening these, keeps the one-click recolour a click deeper but the board legible.
struct SpaceTextColorPopover: View {
    /// The box's stored colour, so the matching swatch shows its ring.
    let current: String?
    let onSelect: (String) -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(SpaceTextChromeLayout.swatchSize),
                                spacing: SpaceTextChromeLayout.swatchGap),
            count: SpaceTextChromeLayout.paletteColumns)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: SpaceTextChromeLayout.swatchGap) {
            ForEach(TextPalette.swatches) { swatch in
                SwatchDot(
                    swatch: swatch,
                    isCurrent: TextPalette.matches(swatch, storedHex: current),
                    action: { onSelect(swatch.hex) })
            }
        }
        .padding(Theme.Spacing.lg)
        .fixedSize()
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
