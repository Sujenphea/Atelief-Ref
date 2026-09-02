// AtelierBrowse — how the detail screen words a fact (093 § 2).
//
// The phone's item detail keeps the Mac's three 041 sections in the same order, so it
// keeps the Mac's wording too: `DetailFormat` (`ItemDetailView.swift:2454`–`:2475`),
// restated here for the reason the manifest gives. Two of these read as trivia and are
// not: the saved date is deliberately `dd/MM/yyyy` and locale-INDEPENDENT (it is the
// Figma's format, 041), and the platform labels are the app's own spellings —
// "Twitter / X", lowercase "rednote", "Dragged in" — which a `rawValue` would get
// wrong in five places out of nine.

import AtelierCore
import Foundation

/// Value formatting for the phone's item detail — a namespace, `static` only.
public enum BrowseFormat {
    /// `dd/MM/yyyy` — the Figma "Saved" format (041), locale-independent.
    /// `DetailFormat.savedDate` (`ItemDetailView.swift:2456`).
    public static func savedDate(
        _ date: Date, calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        return String(
            format: "%02d/%02d/%04d",
            components.day ?? 0, components.month ?? 0, components.year ?? 0)
    }

    /// A human-facing label for a capture platform.
    /// `DetailFormat.platform` (`ItemDetailView.swift:2462`).
    public static func platform(_ platform: Platform) -> String {
        switch platform {
        case .twitter: "Twitter / X"
        case .pinterest: "Pinterest"
        case .instagram: "Instagram"
        case .cosmos: "Cosmos"
        case .rednote: "rednote"
        case .web: "Web"
        case .clipboard: "Clipboard"
        case .localPaste: "Pasted"
        case .localDrag: "Dragged in"
        }
    }

    /// `"1668px x 2500px"`, or `nil` for a media-less kind with no dimensions —
    /// the row is omitted rather than shown empty (`ItemDetailView.swift:1741`).
    public static func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height else { return nil }
        return "\(width)px x \(height)px"
    }

    /// `"Name (@handle)"` when both are present, whichever exists otherwise, `nil` when
    /// neither does. Blank and whitespace-only values count as absent.
    /// `SourceSection.author` (`ItemDetailView.swift:1762`).
    public static func author(name: String?, handle: String?) -> String? {
        let trimmedName = nonBlank(name)
        let trimmedHandle = nonBlank(handle)
        switch (trimmedName, trimmedHandle) {
        case let (name?, handle?): return "\(name) (\(handle))"
        case let (name?, nil): return name
        case let (nil, handle?): return handle
        case (nil, nil): return nil
        }
    }

    /// The item's display title: the user's own name for it, else the source's title,
    /// else `nil` — the detail screen falls back to the kind.
    public static func title(name: String?, sourceTitle: String?) -> String? {
        nonBlank(name) ?? nonBlank(sourceTitle)
    }

    /// A trimmed value, or `nil` when it is absent, empty, or whitespace only —
    /// `TextRules.nonBlank`, which is the one statement of that rule (457). Kept as an
    /// entry point because the app's tiles and detail screen call it by this name; it
    /// decides nothing of its own.
    public static func nonBlank(_ value: String?) -> String? {
        TextRules.nonBlank(value)
    }
}
