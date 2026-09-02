// AtelierCore — the one place emptiness is decided (457).
//
// "Trim, and an empty result means absent" was spelled four times across three packages:
// `ShareCapture.normalizedTitle` decided what an empty share title was, `PageHarvest`
// decided it again for a page's URL and canonical, `BrowseFormat.nonBlank` decided it for
// every field the phone's detail screen shows, and `SearchRules` for a saved query. Four
// copies of one rule agreeing today is four chances to disagree the day one of them learns
// about a zero-width space — and a title that is blank on the phone and present on the Mac
// is a capture the two sides render differently for no reason a user could see.
//
// It lives in AtelierCore because every producer and every reader links AtelierCore, and
// nothing below it. `AtelierLibraryPaths.LibraryLocation.overrideValue` still spells the
// rule inline, and says why: that package has no dependencies by charter.

import Foundation

/// Rules over plain text that more than one package applies. A namespace — `static` only.
public enum TextRules {
    /// `value` trimmed of whitespace and newlines, or `nil` when it is absent, empty, or
    /// nothing but whitespace.
    ///
    /// Trimming rather than merely testing, because a title arriving with a trailing
    /// newline is the same title, and a blank stored where a reader expects "a title or
    /// nothing" is a blank line in a grid tile.
    public static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
