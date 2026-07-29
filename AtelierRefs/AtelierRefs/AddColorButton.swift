//
//  AddColorButton.swift
//  AtelierRefs
//
//  The C1 entry point for saving a COLOR item (003 · multi-kind items). A
//  toolbar button that opens a small popover: a native `ColorPicker` and a hex
//  field kept in sync, plus one Add action. The hex field is the source of truth
//  (canonicalized by the domain), so a picked color and a typed `#rrggbb` commit
//  through the same path. Validation/dedup live in the funnel; this only gathers
//  a hex and hands it to `onAdd`.
//

import AtelierCore
import SwiftUI

/// A toolbar affordance to add a color to the current collection. `onAdd`
/// receives a user hex (`#rrggbb` or shorthand / picked color) — the funnel
/// canonicalizes and dedups it.
struct AddColorButton: View {
    let onAdd: (String) -> Void

    @State private var showing = false
    @State private var picked: Color = .accentColor
    @State private var hexText = ""

    /// Enabled only when the field holds a valid hex color.
    private var canonical: String? { ColorPayload.canonicalHex(hexText) }

    var body: some View {
        Button {
            // Seed the field from the current picker so the popover opens ready.
            hexText = picked.toHexString() ?? "#000000"
            showing = true
        } label: {
            Label("Add Color", systemImage: "paintpalette")
        }
        .help("Add a color swatch to this collection")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Color").font(.headline)

                // Picking writes its hex into the field (single source of truth).
                ColorPicker("Pick a color", selection: $picked, supportsOpacity: false)
                    .onChange(of: picked) { _, newValue in
                        if let hex = newValue.toHexString() { hexText = hex }
                    }

                HStack(spacing: 8) {
                    TextField("#RRGGBB", text: $hexText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit(commit)
                    // A live swatch of what will be added.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hexString: canonical ?? "") ?? Color(.quaternaryLabelColor))
                        .frame(width: 28, height: 28)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                        }
                }

                HStack {
                    Spacer()
                    Button("Add", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(canonical == nil)
                }
            }
            .popoverContent(width: 260)
        }
    }

    private func commit() {
        guard let hex = canonical else { return }
        onAdd(hex)
        showing = false
    }
}
