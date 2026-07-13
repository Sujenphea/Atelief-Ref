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

import AtelierCore
import CanvasRenderer
import SwiftUI

struct ElementInspector: View {
    let kind: SpaceItemKind
    let initialStyle: ElementStyle
    let onCommit: (ElementStyle) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var fontSize: Double
    @State private var textColor: Color
    @State private var fillEnabled: Bool
    @State private var fillColor: Color
    @State private var strokeColor: Color
    @State private var strokeWidth: Double

    init(kind: SpaceItemKind, initialStyle: ElementStyle,
         onCommit: @escaping (ElementStyle) -> Void, onDelete: @escaping () -> Void) {
        self.kind = kind
        self.initialStyle = initialStyle
        self.onCommit = onCommit
        self.onDelete = onDelete
        _text = State(initialValue: initialStyle.text ?? "")
        _fontSize = State(initialValue: initialStyle.fontSize ?? ElementRendering.defaultFontSize)
        _textColor = State(initialValue: Color(rgba:
            ElementRendering.rgba(fromHex: initialStyle.textColor) ?? RGBAColor(red: 0.07, green: 0.07, blue: 0.07)))
        _fillEnabled = State(initialValue: initialStyle.fillColor != nil)
        _fillColor = State(initialValue: Color(rgba:
            ElementRendering.rgba(fromHex: initialStyle.fillColor) ?? RGBAColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1)))
        _strokeColor = State(initialValue: Color(rgba:
            ElementRendering.rgba(fromHex: initialStyle.strokeColor) ?? RGBAColor(red: 0.56, green: 0.56, blue: 0.58)))
        _strokeWidth = State(initialValue: initialStyle.strokeWidth ?? ElementRendering.defaultFrameStrokeWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .text ? "Text" : "Frame").font(.headline)

            if kind == .text {
                textEditor
            } else {
                frameEditor
            }

            Divider()
            HStack {
                Button(role: .destructive) { onDelete(); dismiss() } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                Button("Done") { commit(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
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
                .textFieldStyle(.roundedBorder)
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
        var style = initialStyle
        switch kind {
        case .text:
            style.text = text
            style.fontSize = fontSize
            style.textColor = ElementRendering.hex(from: textColor.rgbaComponents())
        case .frame:
            style.text = text.isEmpty ? nil : text
            style.textColor = ElementRendering.hex(from: textColor.rgbaComponents())
            style.strokeColor = ElementRendering.hex(from: strokeColor.rgbaComponents())
            style.strokeWidth = strokeWidth
            style.fillColor = fillEnabled ? ElementRendering.hex(from: fillColor.rgbaComponents()) : nil
        case .asset:
            break
        }
        onCommit(style)
    }
}
