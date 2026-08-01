//
//  AddLinkForm.swift
//  AtelierRefs
//
//  The C2 entry point for saving a LINK item (003 · multi-kind items): a URL field
//  whose committed value goes to `onAdd`, which routes it through `ingestContent` —
//  the funnel canonicalizes it (that's the dedup key), resolves og: metadata to fill
//  the card, and rejects a non-http(s) URL. A bare paste still saves.
//
//  Was `AddLinkButton`, orphaned when 006 removed the toolbar it lived on. Now just
//  the popover BODY the floating "+" raises — hence no trigger, and `onDismiss` from
//  outside.
//

import AtelierCore
import SwiftUI

/// Gather a link to add to a collection. `onAdd` receives a user URL — the funnel
/// canonicalizes, dedups, and validates it.
struct AddLinkForm: View {
    let onAdd: (String) -> Void
    let onDismiss: () -> Void

    @State private var urlText = ""

    /// Enabled only when the field holds a canonicalizable http(s) URL.
    private var isValid: Bool { LinkPayload.canonicalURL(urlText) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Add Link").font(Theme.Typography.bodyEmphasis)
            TextField("https://example.com/…", text: $urlText)
                .textFieldStyle(.plain)
                .dialogFieldChrome()
                .onSubmit(commit)
            Button("Add", action: commit)
                .buttonStyle(DialogButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        // The CARD carries the width now. It used to come from the field's own
        // `.frame(width: 320)`, which a full-width button underneath would have had to
        // duplicate to line up with it.
        .popoverContent(width: 320)
    }

    private func commit() {
        guard isValid else { return }
        onAdd(urlText)
        onDismiss()
    }
}
