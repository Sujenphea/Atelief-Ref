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
        let trimmedName = TextRules.nonBlank(name)
        let trimmedHandle = TextRules.nonBlank(handle)
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
        TextRules.nonBlank(name) ?? TextRules.nonBlank(sourceTitle)
    }

    /// A link tile's title: the source's own title if it has one, else the site it came
    /// from, else the raw URL (098 · "also found").
    ///
    /// **Why the host is worth a function.** A tier-1 link share on the phone has NO
    /// title. `ShareCapture.swift` and 092 · S4b both say the drain enriches a link with
    /// og-tags, and neither is true: `InboxDrain.makeInput` routes a `link` to
    /// `remoteContent`, and `PageResolver` is only ever called from the Mac's paste path.
    /// So the tile fell through to `link.url` and drew a full URL — query string,
    /// tracking parameters and all — in a two-line label at column width. Every bare link
    /// on the phone looked like that.
    ///
    /// **No network.** This is the read side; the fix for the missing og-tags is Mac-side
    /// enrichment after import and it is outside this pass. What can be said without
    /// asking anyone is where the link points, and that is what a person recognises.
    public static func linkTitle(_ title: String?, url: String) -> String {
        TextRules.nonBlank(title) ?? hostName(of: url) ?? url
    }

    /// The site a URL points at: lower-cased, `www.` dropped, userinfo and port and path
    /// gone. `nil` for anything with no host — a relative string, a `mailto:`, a
    /// scheme-less "example.com/x", or plain prose.
    ///
    /// **The ASCII form, deliberately.** `URL.host(percentEncoded: false)` answers the
    /// punycode (`xn--…`) spelling for an internationalised host, and `URLComponents.host`
    /// answers the Unicode one. The Unicode one is prettier and it is also a homograph
    /// surface: a tile is exactly the place a lookalike domain would want to be rendered
    /// as the site it is imitating. This is a label on a capture whose provenance the user
    /// may be about to trust, so it shows what the resolver will actually use.
    ///
    /// `www.` goes because it is not information — it is the same site — and a 20-point
    /// label at column width has no room for four characters that say nothing.
    public static func hostName(of url: String?) -> String? {
        guard let raw = TextRules.nonBlank(url),
              let host = URL(string: raw)?.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return TextRules.nonBlank(bare)
    }
}
