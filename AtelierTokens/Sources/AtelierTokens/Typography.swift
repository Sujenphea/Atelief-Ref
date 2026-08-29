// AtelierTokens — the text roles.
//
// Each is a text style plus a weight, **never a point size**, and that is the whole
// argument: `Font.system(size:)` does not scale with the Accessibility text-size setting,
// and `Font.system(size:weight:relativeTo:)` — which would give exact sizes AND scaling —
// does not exist. `relativeTo:` belongs to `Font.custom`, which needs a font NAME, and the
// only name matching the system font's metrics is the private `.AppleSystemUIFont`, which
// CoreText warns against; a name that stops resolving falls back silently
// (`.SFNS-Regular` yields Times New Roman). So the sizes are Apple's and the app inherits
// Dynamic Type for free.
//
// That reasoning was written for a Mac and pays off far more on a phone (093 § 4), which
// is a good sign for a token: the argument did not have to change to cross.

import SwiftUI

extension Tokens {
    public enum Typography {
        /// A SHEET / OVERLAY title — chrome that arrived on top of the app and has to
        /// name itself before it can be dismissed. Not a PANE title, however page-like
        /// the pane feels; a pane takes ``sectionTitle``.
        public static let pageTitle = Font.system(.title2, design: .default, weight: .semibold)
        /// The ONE page / section title role — section headers, page titles, and the
        /// detail inspector's headers, so none of them drifts to its own
        /// `.title2`/`.title3`/`.headline`.
        public static let sectionTitle = Font.system(.title3, design: .default, weight: .semibold)
        /// Sidebar top-nav rows. macOS only — the phone's one destination is its title
        /// (093 § 2), so there is no nav list to give a role to.
        public static let navItem = Font.system(.title2, design: .default, weight: .medium)
        /// Sidebar collection rows, chip and field text.
        public static let row = Font.system(.body, design: .default, weight: .regular)
        /// Emphasised body — a card title, a list row's heading.
        public static let bodyEmphasis = Font.system(.headline, design: .default, weight: .semibold)
        /// Running text: descriptions, toast messages, secondary rows.
        public static let body = Font.system(.callout, design: .default, weight: .regular)
        /// The count label in a floating action bar ("16 selected") — ``body``'s size at
        /// medium weight, so a short string holds its own beside 15pt glyphs. A ROLE
        /// rather than a `.weight(.medium)` applied at a call site: the app defines its
        /// text sizes here precisely so a specimen page can show them, and a weight
        /// applied at a call site is a size decision made where nothing can see it.
        public static let barLabel = Font.system(.callout, design: .default, weight: .medium)
        /// Metadata labels and values.
        public static let label = Font.system(.subheadline, design: .default, weight: .regular)
        /// The smallest text the app draws — captions, counters, badge numerals.
        public static let caption = Font.system(.caption2, design: .default, weight: .regular)
        /// A value that is a STRING OF CHARACTERS rather than a word — the capture
        /// pairing token, and anything else where the reader's job is to compare or
        /// transcribe it glyph by glyph. Monospaced so `0`/`O` and `1`/`l` separate.
        public static let mono = Font.system(.body, design: .monospaced)
    }
}
