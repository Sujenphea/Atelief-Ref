//
//  ElementInspector.swift
//  AtelierRefs
//
//  005-E3 — the popover editor for a selected freeform element (frame or text).
//  Decision (open-Q, chosen): a popover `TextField` rather than an inline canvas
//  overlay — robust, with no overlay↔canvas coordinate mapping under pan/zoom.
//  Edits a LOCAL `ElementStyle` copy and commits on Done (one write + reload),
//  so typing doesn't rebuild the canvas host per keystroke.
//

import AppKit
import AtelierCore
import CanvasRenderer
import SwiftUI

struct ElementInspector: View {
    let kind: SpaceItemKind
    let initialStyle: ElementStyle
    let onCommit: (ElementStyle) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Set once Done or Delete has handled the close, so the commit-on-dismiss
    /// fallback (below) doesn't double-write or resurrect a just-deleted element.
    @State private var finished = false
    @State private var text: String
    @State private var fontSize: Double
    @State private var textColor: Color
    @State private var fillEnabled: Bool
    @State private var fillColor: Color
    @State private var strokeColor: Color
    @State private var strokeWidth: Double
    /// The selected font family, or `""` for the system-font sentinel.
    @State private var fontFamily: String
    @State private var weight: TextWeight
    @State private var align: TextAlign
    /// 063 — whether the box derives its own width. `Bool` rather than the
    /// `ElementStyle` optional: the control has two positions, and an absent value
    /// means "fixed" everywhere else too.
    @State private var autoWidth: Bool

    /// The system-font sentinel used as the "System" picker tag / empty family.
    /// ``FontFamilyPicker`` owns the list itself (064), shared with the board's own
    /// font popover so the two ways into this setting can't drift.
    private static let systemFamily = FontFamilyCatalog.systemFamily

    init(kind: SpaceItemKind, initialStyle: ElementStyle,
         onCommit: @escaping (ElementStyle) -> Void, onDelete: @escaping () -> Void) {
        self.kind = kind
        self.initialStyle = initialStyle
        self.onCommit = onCommit
        self.onDelete = onDelete
        _text = State(initialValue: initialStyle.text ?? "")
        _fontSize = State(initialValue: initialStyle.fontSize ?? ElementRendering.defaultFontSize)
        _textColor = State(initialValue: Color(rgba:
            ElementRendering.rgba(fromHex: initialStyle.textColor) ?? ElementRendering.defaultTextColor))
        _fillEnabled = State(initialValue: initialStyle.fillColor != nil)
        _fillColor = State(initialValue: Color(rgba:
            ElementRendering.rgba(fromHex: initialStyle.fillColor) ?? RGBAColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1)))
        _strokeColor = State(initialValue: Color(rgba:
            ElementRendering.rgba(fromHex: initialStyle.strokeColor) ?? RGBAColor(red: 0.56, green: 0.56, blue: 0.58)))
        _strokeWidth = State(initialValue: initialStyle.strokeWidth ?? ElementRendering.defaultFrameStrokeWidth)
        _fontFamily = State(initialValue: initialStyle.fontFamily ?? Self.systemFamily)
        _weight = State(initialValue: initialStyle.weight)
        _align = State(initialValue: initialStyle.align)
        _autoWidth = State(initialValue: initialStyle.hugsWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .text ? "Text" : "Frame").font(Theme.Typography.bodyEmphasis)

            if kind == .text {
                textEditor
            } else {
                frameEditor
            }

            Divider()
            HStack {
                Button(role: .destructive) { finished = true; onDelete(); dismiss() } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                Button("Done") { finished = true; commit(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            // `role: .destructive` stays cosmetically inert, as it does in the selection
            // action bar: the app's chrome is monochrome, and the confirmation lives in
            // the model call rather than in a red tint.
            .buttonStyle(DialogButtonStyle(width: .hug))
        }
        // A popover supplies no inset of its own, and at 14 the pickers and the
        // Done/Delete row sat against its chrome. `lg` on the design scale, shared
        // with the board's font popover (062) so the two read as one control set.
        .popoverContent(width: 340)
        // Dismissing the popover by clicking outside used to discard every edit.
        // Commit those pending edits instead (unless Done/Delete already closed it).
        // `onDisappear` runs INSIDE the view-removal update, and `onCommit`
        // publishes on the SpaceModel (undo token + reload) — doing that
        // synchronously here trips "Publishing changes from within view updates."
        // Build the style now (reading local state), then hop off the update frame
        // to publish. Done/Delete commit synchronously from their button actions
        // (not a view update), so only this fallback needs the defer.
        .onDisappear {
            guard !finished else { return }
            let style = builtStyle()
            Task { @MainActor in onCommit(style) }
        }
    }

    // The string is edited on-canvas (2B), not here (R3) — the popover keeps only
    // the STYLE controls (family / weight / align / width / size / colour).
    //
    // The HEIGHT is still not a setting and never will be: it follows the text (062).
    // The WIDTH became one in 063 — a box either hugs its text or holds the width the
    // handles gave it, and that is a state the user picks rather than infers. This
    // comment previously read "sizing is not a setting"; half of it is now wrong,
    // which is why it says so rather than being quietly deleted.
    @ViewBuilder private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FontFamilyPicker(selection: $fontFamily)
            // Full-width rather than label-left: four weight names do not fit beside a
            // label in this card, which is why these were `.segmented` pickers spanning
            // the popover before. The labels move above the row instead.
            DialogStack("Weight") {
                SegmentedControl(
                    selection: $weight, values: TextWeight.allCases, fillsWidth: true
                ) {
                    Text($0.rawValue.capitalized)
                }
            }
            DialogStack("Align") {
                SegmentedControl(
                    selection: $align, values: TextAlign.allCases, fillsWidth: true
                ) {
                    Image(systemName: $0.symbolName)
                }
            }
            DialogStack("Width") {
                SegmentedControl(selection: $autoWidth, values: [true, false], fillsWidth: true) {
                    Text($0 ? "Auto" : "Fixed")
                }
            }
            HStack {
                Text("Size").frame(width: 44, alignment: .leading)
                Slider(value: $fontSize, in: 8...96)
                Text("\(Int(fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            ColorPicker("Colour", selection: $textColor, supportsOpacity: false)
        }
    }

    @ViewBuilder private var frameEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (optional)", text: $text)
                .textFieldStyle(.plain)
                .dialogFieldChrome()
            ColorPicker("Border", selection: $strokeColor, supportsOpacity: false)
            HStack {
                Text("Width").frame(width: 44, alignment: .leading)
                Slider(value: $strokeWidth, in: 0...12)
                Text("\(Int(strokeWidth))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            Toggle("Fill", isOn: $fillEnabled)
            if fillEnabled {
                ColorPicker("Fill colour", selection: $fillColor, supportsOpacity: true)
            }
        }
    }

    private func commit() {
        onCommit(builtStyle())
    }

    /// The `ElementStyle` for the current editor state — pure (reads local state
    /// only, publishes nothing), so it's safe to call from `onDisappear`.
    private func builtStyle() -> ElementStyle {
        var style = initialStyle
        switch kind {
        case .text:
            style.text = text
            style.fontSize = fontSize
            style.textColor = ElementRendering.hex(from: textColor.rgbaComponents())
            style.fontFamily = fontFamily.isEmpty ? nil : fontFamily
            style.fontWeight = weight.rawValue
            style.textAlign = align.rawValue
            style.textAutoWidth = autoWidth
        case .frame:
            style.text = text.isEmpty ? nil : text
            style.textColor = ElementRendering.hex(from: textColor.rgbaComponents())
            style.strokeColor = ElementRendering.hex(from: strokeColor.rgbaComponents())
            style.strokeWidth = strokeWidth
            style.fillColor = fillEnabled ? ElementRendering.hex(from: fillColor.rgbaComponents()) : nil
        case .asset:
            break
        }
        return style
    }
}

extension TextAlign {
    /// The SF Symbol for the alignment segmented control — shared with the board's
    /// floating format bubble (062), so the two controls can't drift.
    var symbolName: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}
