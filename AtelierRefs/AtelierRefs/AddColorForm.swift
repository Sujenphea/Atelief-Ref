//
//  AddColorForm.swift
//  AtelierRefs
//
//  The C1 entry point for saving a COLOR item (003 · multi-kind items): a native
//  `ColorPicker` and a hex field kept in sync, plus one Add action. The hex field is
//  the source of truth (canonicalized by the domain), so a picked color and a typed
//  `#rrggbb` commit through the same path. Validation/dedup live in the funnel; this
//  only gathers a hex and hands it to `onAdd`.
//
//  Was `AddColorButton` — a toolbar button that owned its own popover. The toolbar it
//  belonged to was removed by 006 and nothing ever adopted the button, so the whole
//  picker sat orphaned while the floating "+" shipped a hardcoded `#2C2C30` swatch in
//  its place. It is now just the BODY: the "+" raises it (`FloatingAddItem.popover`),
//  which is why the trigger is gone and `onDismiss` arrives from outside.
//

import AtelierCore
import SwiftUI

/// Gather a color to add to a collection. `onAdd` receives a user hex (`#rrggbb` or
/// shorthand / picked color) — the funnel canonicalizes and dedups it.
struct AddColorForm: View {
    let onAdd: (String) -> Void
    let onDismiss: () -> Void

    @State private var picked: Color = .accentColor
    @State private var hexText = ""

    /// Enabled only when the field holds a valid hex color.
    private var canonical: String? { ColorPayload.canonicalHex(hexText) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Add Color").font(.headline)

            // Picking writes its hex into the field (single source of truth).
            ColorPicker("Pick a color", selection: $picked, supportsOpacity: false)
                .onChange(of: picked) { _, newValue in
                    if let hex = newValue.toHexString() { hexText = hex }
                }

            HStack(spacing: Theme.Spacing.sm) {
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(commit)
                // A live swatch of what will be added.
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(Color(hexString: canonical ?? "") ?? Color(.quaternaryLabelColor))
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
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
        // Seed the field from the picker so the form opens ready to commit.
        .onAppear { if hexText.isEmpty { hexText = picked.toHexString() ?? "#000000" } }
    }

    private func commit() {
        guard let hex = canonical else { return }
        onAdd(hex)
        onDismiss()
    }
}
