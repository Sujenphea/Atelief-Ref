//
//  CollectionCell.swift
//  AtelierRefs
//
//  009 · N2 — one Library grid cell: the asset thumbnail plus the hover/selection
//  circle and the keyboard-cursor ring. It routes RAW input up (which id, which
//  modifiers, image-tap vs circle-tap) and never decides selection mode itself —
//  the pure ``GridSelection`` reducer does (11A). `Equatable` on its value inputs
//  so an unchanged cell skips re-render during marquee / selection churn (13A);
//  the action closures are deliberately excluded from `==`.
//

import AppKit
import AtelierCore
import SwiftUI

struct CollectionCell: View, Equatable {
    let detail: CollectionItemDetail
    /// The on-disk 512-tier thumbnail URL (nil for media-less kinds).
    let url: URL?
    /// In the selection set — draws the filled check + selection border.
    let isSelected: Bool
    /// The keyboard/detail cursor (`lead`) — draws a focus ring when it isn't
    /// also selected (a selected cell already reads as focused).
    let isCursor: Bool
    /// Selection mode is active somewhere in the grid — circles show on ALL cells
    /// so any of them can be toggled, not just the hovered one.
    let isSelecting: Bool
    /// The mouse-DOWN edge on the image, BEFORE `.draggable` can steal the
    /// interaction (009: Finder's press routing). Returns whether the press
    /// consumed it — the cell then swallows the matching mouse-up click.
    let onImagePress: (_ shift: Bool, _ command: Bool) -> Bool
    /// A plain/⇧/⌘ click on the image (mouse-up, when the press didn't consume).
    /// The booleans are the live modifier state read at click time; the parent
    /// maps them to a reducer action.
    let onImageClick: (_ shift: Bool, _ command: Bool) -> Void
    /// A click on the circle — always a plain toggle (enters/exits selection).
    let onCircleToggle: () -> Void

    @State private var isHovering = false
    /// Set on the down edge when the press already applied the action; the
    /// mouse-up Button action checks-and-ignores, and the release edge resets it
    /// (covering a press whose click was cancelled by a drag).
    @State private var imagePressConsumed = false
    @State private var circlePressConsumed = false

    /// Value-equality for `.equatable()` — closures excluded on purpose so a
    /// parent re-render that rebuilds the closures doesn't invalidate the cell.
    static func == (lhs: CollectionCell, rhs: CollectionCell) -> Bool {
        lhs.detail.item.id == rhs.detail.item.id
            && lhs.detail.asset == rhs.detail.asset
            && lhs.url == rhs.url
            && lhs.isSelected == rhs.isSelected
            && lhs.isCursor == rhs.isCursor
            && lhs.isSelecting == rhs.isSelecting
    }

    /// The circle is visible while selecting (every cell, so all are toggleable)
    /// or, when idle, only on the hovered cell (the pointer-only entry affordance).
    private var showsCircle: Bool { isSelecting || isHovering }

    var body: some View {
        Button {
            if imagePressConsumed { return }
            // A modified click is handled by the ⌘/⇧ tap gestures below; a SwiftUI
            // `Button` doesn't reliably activate on a modified click, so the plain
            // action only ever handles an UNMODIFIED click (open when idle, toggle
            // when selecting). Bailing here also stops a double-apply if the button
            // ever does fire under a held modifier.
            let flags = NSEvent.modifierFlags
            guard !flags.contains(.shift), !flags.contains(.command) else { return }
            onImageClick(false, false)
        } label: {
            AssetContentThumbnail(asset: detail.asset, url: url, isSelected: isSelected)
        }
        .buttonStyle(PressReportingButtonStyle(
            onPress: {
                // Only the plain toggle-on-unselected case fires on the down edge
                // (to beat the drag race). ⇧/⌘ deliberately do NOT route through the
                // fragile `isPressed` edge — the modifier tap gestures below own them.
                let flags = NSEvent.modifierFlags
                guard !flags.contains(.shift), !flags.contains(.command) else {
                    imagePressConsumed = false
                    return
                }
                imagePressConsumed = onImagePress(false, false)
            },
            onRelease: { imagePressConsumed = false }))
        // ⌘/⇧ clicks: a SwiftUI `Button` doesn't fire on a modified click and its
        // `isPressed` edge is unreliable under a `.draggable`, so the pure routing
        // never ran for them. Modifier-aware tap gestures fire regardless and
        // coexist with the drag — this is the ONLY path that applies ⌘/⇧ selection.
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { onImageClick(false, true) })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { onImageClick(true, false) })
        .overlay { cursorRing }
        .overlay(alignment: .topTrailing) {
            if showsCircle { circle }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: showsCircle)
    }

    @ViewBuilder
    private var cursorRing: some View {
        if isCursor && !isSelected {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    private var circle: some View {
        Button {
            if circlePressConsumed { return }
            onCircleToggle()
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isSelected ? Color.white : Color.white.opacity(0.95),
                    isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .background(Circle().fill(.black.opacity(0.15)).padding(1))
                .padding(6)
        }
        .buttonStyle(PressReportingButtonStyle(
            onPress: {
                // The circle is ALWAYS a toggle, so it can always fire on the
                // down edge — immune to `.draggable` swallowing the click.
                circlePressConsumed = true
                onCircleToggle()
            },
            onRelease: { circlePressConsumed = false }))
        .help(isSelected ? "Deselect" : "Select")
    }
}

/// A plain-look button style that also reports the press edges. SwiftUI
/// `Button` fires its action on mouse-UP, but every grid cell is `.draggable`:
/// a press with a few points of trackpad drift activates the drag session and
/// the click is silently cancelled. Reporting the down edge lets a cell apply
/// toggle actions immediately (009: Finder-style press routing).
///
/// Ordering contract the consumed-flag relies on: the Button `action` runs
/// synchronously in the mouse-up event, while `onChange` fires on the NEXT
/// render pass — so `onPress` (down-edge render) precedes the action, and
/// `onRelease` follows it. On an ultra-fast tap where no render happens between
/// down and up, `isPressed` is never observed `true`, neither edge fires, and
/// the plain mouse-up action handles the click alone — both paths route through
/// live selection state, so neither double-applies.
struct PressReportingButtonStyle: ButtonStyle {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                pressed ? onPress() : onRelease()
            }
    }
}
