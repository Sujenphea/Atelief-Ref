//
//  NameEntryAlert.swift
//  AtelierRefs
//
//  043 · 6A — the single "New / Rename" name-entry alert behind every collection
//  and space name prompt (sidebar, Home gallery, collection screen). The text
//  field, the blank-guard on the confirm button, and clearing the field on
//  dismiss live here in ONE place; each call site supplies only the title, the
//  confirm label, and the confirm/cancel intents.
//

import SwiftUI

extension View {
    /// A single-field name-entry alert.
    ///
    /// - Parameters:
    ///   - title: the alert title (e.g. "New Subfolder", "Rename Collection").
    ///   - isPresented: drives presentation — a direct `@State` flag or a
    ///     `Binding<Bool>` derived from an optional target.
    ///   - text: the field's backing text. Cleared automatically on confirm AND
    ///     cancel; callers that pre-seed it (rename) re-seed on the next open.
    ///   - confirmLabel: the confirm button title ("Create" / "Rename").
    ///   - onConfirm: given the entered name (raw — trimming/validation is the
    ///     service's job). Reset any associated target state here too.
    ///   - onCancel: reset any associated target state (default no-op).
    ///
    /// The confirm button is disabled while the trimmed text is empty.
    func nameEntryAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        text: Binding<String>,
        confirmLabel: String,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        alert(title, isPresented: isPresented) {
            TextField("Name", text: text)
            Button(confirmLabel) {
                onConfirm(text.wrappedValue)
                text.wrappedValue = ""
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                text.wrappedValue = ""
                onCancel()
            }
        }
    }
}
