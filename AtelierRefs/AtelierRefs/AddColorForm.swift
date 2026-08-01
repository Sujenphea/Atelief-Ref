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

    /// The one `.accentColor` left in the app, and deliberately: this is the colour
    /// the USER is picking — content on its way into the library, not chrome. The
    /// monochrome rule governs what the app draws around the work, not the work.
    @State private var picked: Color = .accentColor
    @State private var hexText = ""

    /// Enabled only when the field holds a valid hex color.
    private var canonical: String? { ColorPayload.canonicalHex(hexText) }

    /// The swatch wears the field's own radius so the pair reads as one control.
    private var swatchShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Add Color").font(Theme.Typography.bodyEmphasis)

            HStack(spacing: Theme.Spacing.sm) {
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.plain)
                    .dialogFieldChrome()
                    .onSubmit(commit)
                // The swatch IS the picker now: clicking it opens the system colour
                // panel, whose pick writes its hex into the field (still the single
                // source of truth). One control in place of the labelled `ColorPicker`
                // row plus the read-only preview that used to sit beside the field.
                ColorSwatchWell(color: $picked)
                    .frame(width: 40, height: 32)
                    .clipShape(swatchShape)
                    .overlay(swatchShape.strokeBorder(
                        Theme.Colors.hairlineStrong, lineWidth: 1))
                    .onChange(of: picked) { _, newValue in
                        if let hex = newValue.toHexString() { hexText = hex }
                    }
                    // …and the swatch follows a TYPED hex back, which the read-only
                    // preview it replaced did for free. Both directions settle after one
                    // hop: writing the same hex back produces no further change.
                    .onChange(of: hexText) { _, _ in
                        guard let hex = canonical, let typed = Color(hexString: hex),
                              typed.toHexString() != picked.toHexString()
                        else { return }
                        picked = typed
                    }
            }

            Button("Add", action: commit)
                .buttonStyle(DialogButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(canonical == nil)
        }
        .popoverContent(width: 280)
        // Seed the field from the picker so the form opens ready to commit.
        .onAppear { if hexText.isEmpty { hexText = picked.toHexString() ?? "#000000" } }
    }

    private func commit() {
        guard let hex = canonical else { return }
        onAdd(hex)
        onDismiss()
    }
}
