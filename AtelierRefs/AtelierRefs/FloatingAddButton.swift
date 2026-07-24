//
//  FloatingAddButton.swift
//  AtelierRefs
//
//  The panel's floating circular "+" add affordance, done in native AppKit. The
//  SwiftUI `Menu` (even with a ZStack-sibling label) would not reliably render the
//  circle fill or the glyph under `.borderlessButton`, and swallowed the click — so
//  this is a layer-backed `NSButton` that pops a native `NSMenu`, wrapped for SwiftUI.
//

import AppKit
import SwiftUI

/// One entry in the floating add menu — a title and the closure to run when picked.
struct FloatingAddItem {
    let title: String
    let action: () -> Void
}

/// A circular `NSButton` whose visible disc is drawn in a dedicated sublayer kept as a
/// CENTERED SQUARE — never derived from the button's own bounds. The cell lays the
/// button out slightly TALLER than its nominal diameter, so a bounds-derived
/// `cornerRadius` produced a rounded rectangle / vertical oval instead of a circle.
/// Sizing the disc to `min(bounds)` and centering it makes the fill a perfect circle
/// regardless of the frame the host hands us; the glyph rides in a sibling sublayer on
/// top (a plain sublayer would otherwise cover the cell-drawn image).
private final class RoundButton: NSButton {
    var diameter: CGFloat = 40 {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// The ink-on-white circle plus its drop shadow.
    let disc = CALayer()
    /// The "+" glyph, drawn above `disc`.
    let glyph = CALayer()

    private var hoverTracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    // MARK: Hover — a subtle lift (stronger shadow + slight scale), the AppKit analogue
    // of the SwiftUI chrome buttons' `HoverButtonStyle` fill. `.inVisibleRect` tracks the
    // live bounds so we never restate the rect on resize.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        disc.shadowRadius = hovered ? 16 : 12
        disc.shadowOpacity = hovered ? 0.7 : 0.55
        // Scale about each layer's center (default anchor 0.5,0.5) so the disc + glyph
        // grow in place; `layout()` only rewrites frames, never the transform.
        let t = CATransform3DMakeScale(hovered ? 1.06 : 1, hovered ? 1.06 : 1, 1)
        disc.transform = t
        glyph.transform = t
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        // Centered square → a real circle no matter how non-square `bounds` is.
        disc.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side)
        disc.cornerRadius = side / 2
        // Pin the shadow to the circle (local coords of `disc`); without a path Core
        // Animation would silhouette the square layer and render flat top/bottom edges.
        disc.shadowPath = CGPath(ellipseIn: disc.bounds, transform: nil)

        // Glyph: a centered square, aspect-fit so it stays crisp at any backing scale.
        let g = side * 0.46
        glyph.frame = CGRect(
            x: bounds.midX - g / 2,
            y: bounds.midY - g / 2,
            width: g,
            height: g)
    }
}

/// A tinted, opaque `CGImage` of the "+" symbol for the glyph sublayer. Rendered large
/// (the disc scales it down via `.resizeAspect`), then flood-filled `.sourceAtop` so the
/// template's alpha becomes solid ink — `contentTintColor` doesn't apply to a raw layer.
private func plusGlyphImage(_ color: NSColor) -> CGImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?
        .withSymbolConfiguration(config) else { return nil }

    let size = symbol.size
    let out = NSImage(size: size)
    out.lockFocus()
    symbol.draw(
        at: .zero,
        from: NSRect(origin: .zero, size: size),
        operation: .sourceOver,
        fraction: 1)
    color.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    out.unlockFocus()

    var rect = NSRect(origin: .zero, size: size)
    return out.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

/// A circular ink-on-white `NSButton` that pops an `NSMenu` built from `items`.
struct FloatingAddButton: NSViewRepresentable {
    var diameter: CGFloat = 40
    var items: [FloatingAddItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = RoundButton()
        button.diameter = diameter
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.imagePosition = .noImage
        button.focusRingType = .none
        // AppKit owns the size: hug the square intrinsic size in both axes so the
        // host can neither stretch nor squash it off 1:1.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)

        button.wantsLayer = true
        button.layer?.masksToBounds = false

        // The visible circle + shadow live on `disc`; `layout()` keeps it a centered
        // square. Mirrors `Theme.Elevation.hover` (AppKit y is not flipped → negative
        // offset = downward shadow).
        button.disc.backgroundColor = NSColor(hex: 0xF2F1EE).cgColor
        button.disc.masksToBounds = false
        button.disc.shadowColor = NSColor.black.cgColor
        button.disc.shadowOpacity = 0.55
        button.disc.shadowRadius = 12
        button.disc.shadowOffset = CGSize(width: 0, height: -6)

        button.glyph.contentsGravity = .resizeAspect
        button.glyph.contents = plusGlyphImage(NSColor(hex: 0x141416))

        // Order matters: `disc` behind, `glyph` in front.
        button.layer?.addSublayer(button.disc)
        button.layer?.addSublayer(button.glyph)

        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        (button as? RoundButton)?.diameter = diameter
    }

    // Hard-lock the layout to a square. Content-hugging only BIASES against stretch;
    // without this, SwiftUI sizes the button from the parent's proposal and it comes
    // out taller/wider than 1:1. Reporting a fixed square size keeps it a circle.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSButton, context: Context
    ) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }

    final class Coordinator: NSObject {
        var items: [FloatingAddItem] = []

        @objc func clicked(_ sender: NSButton) {
            let menu = NSMenu()
            for item in items {
                let mi = NSMenuItem(
                    title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.action
                menu.addItem(mi)
            }

            // Anchor the menu's BOTTOM-RIGHT to the button's TOP-RIGHT (opens upward,
            // right edges flush) — a fixed, predictable FAB position computed in screen
            // space rather than left to `positioning:`-item guesswork. `popUp(in: nil)`
            // places the menu's top-left at the given SCREEN point; the menu draws
            // downward from there, so top-left.y must be raised by the menu's height so
            // its bottom lands just above the button.
            guard let window = sender.window else {
                menu.popUp(positioning: nil, at: .zero, in: sender)
                return
            }
            let onScreen = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            let size = menu.size
            let gap: CGFloat = 8
            let topLeft = NSPoint(
                x: onScreen.maxX - size.width,
                y: onScreen.maxY + size.height + gap)
            menu.popUp(positioning: nil, at: topLeft, in: nil)
        }

        @objc func fire(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }
    }
}
