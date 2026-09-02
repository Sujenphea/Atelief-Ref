// AtelierCore — the one trim-or-nil rule (457).
//
// Four copies of this function agreed by inspection; now there is one, and the
// agreement is a test. The cases are the ones the four call sites each had a reason to
// care about: a share title of spaces, a page URL with a trailing newline, a detail
// field that is empty, a saved search query of tabs.

import Foundation
import Testing

import AtelierCore

@Suite("TextRules (457)")
struct TextRulesTests {

    @Test(
        "absent, empty and whitespace-only values are nil",
        arguments: [nil, "", " ", "   ", "\n", "\t\n ", "\u{00A0}"] as [String?])
    func blankIsNil(value: String?) {
        #expect(TextRules.nonBlank(value) == nil)
    }

    @Test(
        "a present value is trimmed at both ends and otherwise untouched",
        arguments: [
            ("a", "a"),
            (" a ", "a"),
            ("a\n", "a"),
            ("\t two words \n", "two words"),
            ("inner  spaces", "inner  spaces"),
            ("🇬🇧 flag ", "🇬🇧 flag"),
        ])
    func presentIsTrimmed(raw: String, expected: String) {
        #expect(TextRules.nonBlank(raw) == expected)
    }
}
