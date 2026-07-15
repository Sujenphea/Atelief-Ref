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
    /// A plain/⇧/⌘ click on the image. The booleans are the live modifier state
    /// read at click time; the parent maps them to a reducer action.
    let onImageClick: (_ shift: Bool, _ command: Bool) -> Void
    /// A click on the circle — always a plain toggle (enters/exits selection).
    let onCircleToggle: () -> Void

    @State private var isHovering = false

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
            let flags = NSEvent.modifierFlags
            onImageClick(flags.contains(.shift), flags.contains(.command))
        } label: {
            AssetContentThumbnail(asset: detail.asset, url: url, isSelected: isSelected)
        }
        .buttonStyle(.plain)
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
        Button(action: onCircleToggle) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isSelected ? Color.white : Color.white.opacity(0.95),
                    isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .background(Circle().fill(.black.opacity(0.15)).padding(1))
                .padding(6)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Deselect" : "Select")
    }
}
