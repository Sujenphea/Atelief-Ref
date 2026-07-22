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

/// A circular ink-on-white `NSButton` that pops an `NSMenu` built from `items`.
struct FloatingAddButton: NSViewRepresentable {
    var diameter: CGFloat = 40
    var items: [FloatingAddItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
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

        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        button.layer?.cornerRadius = diameter / 2
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
            // Pop from the button's top edge; AppKit flips it upward automatically when
            // there isn't room below (the button lives at the panel's bottom-right).
            let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }

        @objc func fire(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }
    }
}
