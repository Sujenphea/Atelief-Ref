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

/// A square `NSButton` that stays perfectly circular: it reports a square intrinsic
/// size and re-derives `cornerRadius` from its height on every layout pass (a fixed
/// radius went stale whenever the laid-out height drifted from the nominal diameter).
private final class RoundButton: NSButton {
    var diameter: CGFloat = 40

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        // Round from the SMALLER side so a non-square laid-out bounds never leaves a
        // flat edge; on a 40×40 frame both sides match and this is a full circle.
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        // Pin the shadow to the CIRCLE. Without an explicit path, Core Animation
        // derives the shadow silhouette from the layer's opaque content — the cell
        // fills its SQUARE bounds — so the drop-shadow rendered with sharp top/bottom
        // corners even though the fill was round. An ellipse path makes it round.
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }
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
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.contentTintColor = NSColor(hex: 0x141416)

        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?
            .withSymbolConfiguration(config)

        button.wantsLayer = true
        if let layer = button.layer {
            layer.backgroundColor = NSColor(hex: 0xF2F1EE).cgColor
            layer.cornerRadius = diameter / 2
            layer.masksToBounds = false
            // Mirrors `Theme.Elevation.hover` (AppKit y is not flipped → negative =
            // downward shadow).
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: -6)
        }

        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        (button as? RoundButton)?.diameter = diameter
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
