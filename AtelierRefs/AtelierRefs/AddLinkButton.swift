//
//  AddLinkButton.swift
//  AtelierRefs
//
//  The C2 entry point for saving a LINK item (003 · multi-kind items). A toolbar
//  button with a popover URL field; committing hands the raw URL to `onAdd`,
//  which routes it through `ingestContent` — the funnel canonicalizes it (that's
//  the dedup key) and rejects a non-http(s) URL. Title/description enrichment
//  arrives later with a page resolver (001); a bare paste still saves.
//

import AtelierCore
import SwiftUI

/// A toolbar affordance to add a link to the current collection. `onAdd`
/// receives a user URL — the funnel canonicalizes, dedups, and validates it.
struct AddLinkButton: View {
    let onAdd: (String) -> Void

    @State private var showing = false
    @State private var urlText = ""

    /// Enabled only when the field holds a canonicalizable http(s) URL.
    private var isValid: Bool { LinkPayload.canonicalURL(urlText) != nil }

    var body: some View {
        Button {
            urlText = ""
            showing = true
        } label: {
            Label("Add Link", systemImage: "link.badge.plus")
        }
        .help("Save a link to this collection")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Link").font(.headline)
                TextField("https://example.com/…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit(commit)
                HStack {
                    Spacer()
                    Button("Add", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
            }
            .padding()
        }
    }

    private func commit() {
        guard isValid else { return }
        onAdd(urlText)
        showing = false
    }
}
