// AtelierCore — FTS query-builder unit tests (044/045 · search overhaul 5A/14A/6A)
//
// Pure string-level tests for the two query builders `searchAssets` leans on:
//   • `ftsMatchQuery` — arbitrary user text → a safe FTS5 MATCH string with a
//     type-ahead PREFIX on the trailing term (5A/14A);
//   • `containsPattern` — a needle → an escaped `%…%` LIKE pattern (6A).
// These are exercised end-to-end by the integration suite too; here we pin the
// exact emitted syntax so a regression names the rule it broke, not a DB miss.

import Testing
@testable import AtelierCore

@Suite("FTS query builder (044/045)")
struct FTSQueryBuilderTests {

    // MARK: ftsMatchQuery — prefix on the trailing term

    @Test("empty / whitespace-only input → empty query (no match-everything)")
    func emptyInputs() {
        #expect(AppServices.ftsMatchQuery("") == "")
        #expect(AppServices.ftsMatchQuery("   ") == "")
        #expect(AppServices.ftsMatchQuery("\t\n ") == "")
    }

    @Test("a single ≥2-char term is a prefix token as the user types")
    func singleTermPrefix() {
        #expect(AppServices.ftsMatchQuery("wood") == "\"wood\"*")
    }

    @Test("a trailing space means the word is finished → exact, no star")
    func trailingSpaceSuppressesPrefix() {
        #expect(AppServices.ftsMatchQuery("wood ") == "\"wood\"")
        #expect(AppServices.ftsMatchQuery("brass wood ") == "\"brass\" \"wood\"")
    }

    @Test("only the FINAL term is a prefix; earlier terms are exact")
    func onlyLastTermPrefixed() {
        #expect(AppServices.ftsMatchQuery("brass wood") == "\"brass\" \"wood\"*")
    }

    @Test("a 1-char trailing term is NOT starred (avoids a huge-slice prefix)")
    func singleCharNotPrefixed() {
        #expect(AppServices.ftsMatchQuery("a") == "\"a\"")
        // …but a preceding complete word still matches exactly.
        #expect(AppServices.ftsMatchQuery("brass a") == "\"brass\" \"a\"")
    }

    @Test("embedded quotes are doubled (FTS5 escaping) and never break out")
    func embeddedQuotesEscaped() {
        // a"b → "a""b"*  (doubled quote, still one prefix token)
        #expect(AppServices.ftsMatchQuery("a\"b") == "\"a\"\"b\"*")
        // a lone quote is a 1-char term → exact, doubled.
        #expect(AppServices.ftsMatchQuery("\"") == "\"\"\"\"")
    }

    @Test("FTS5 operators inside a term are neutralized as literal text")
    func operatorsNeutralized() {
        // The `*` here is literal content, not the prefix operator; the prefix
        // star we add sits OUTSIDE the closing quote.
        #expect(AppServices.ftsMatchQuery("star*") == "\"star*\"*")
        // Splits into three whitespace terms; the bare `OR` becomes a quoted
        // literal (not the FTS5 OR operator), only the last term is a prefix.
        #expect(AppServices.ftsMatchQuery("(foo OR bar)") == "\"(foo\" \"OR\" \"bar)\"*")
    }

    @Test("multibyte / unicode terms count graphemes for the 2-char rule")
    func unicodeTerms() {
        // "café" is ≥2 chars → prefixed.
        #expect(AppServices.ftsMatchQuery("café") == "\"café\"*")
    }

    // MARK: containsPattern — escaped LIKE CONTAINS

    @Test("wraps a plain needle in %…%")
    func containsPlain() {
        #expect(AppServices.containsPattern("sf") == "%sf%")
    }

    @Test("escapes LIKE wildcards so they match literally, not everything")
    func containsEscapesWildcards() {
        // % and _ are LIKE wildcards; a leading `\` is the escape char itself.
        #expect(AppServices.containsPattern("50%") == "%50\\%%")
        #expect(AppServices.containsPattern("a_b") == "%a\\_b%")
        #expect(AppServices.containsPattern("c\\d") == "%c\\\\d%")
    }

    // MARK: trigramMatchQuery — substring MATCH, ≥3-char eligibility (046 Phase 2)

    @Test("empty / whitespace-only input → nil (no trigram arm)")
    func trigramEmptyInputs() {
        #expect(AppServices.trigramMatchQuery("") == nil)
        #expect(AppServices.trigramMatchQuery("   ") == nil)
        #expect(AppServices.trigramMatchQuery("\t\n ") == nil)
    }

    @Test("a single ≥3-char term is one quoted phrase (substring, no prefix star)")
    func trigramSingleTerm() {
        #expect(AppServices.trigramMatchQuery("chair") == "\"chair\"")
        // Exactly 3 chars is the minimum eligible length (one trigram).
        #expect(AppServices.trigramMatchQuery("air") == "\"air\"")
    }

    @Test("a <3-char term makes the WHOLE query ineligible → nil (AND stays exact)")
    func trigramShortTermIneligible() {
        #expect(AppServices.trigramMatchQuery("ab") == nil)
        #expect(AppServices.trigramMatchQuery("a") == nil)
        // One short term among long ones disqualifies the whole query — the caller
        // falls back to unicode61 rather than dropping "ui" and loosening the AND.
        #expect(AppServices.trigramMatchQuery("modern ui") == nil)
    }

    @Test("multiple ≥3-char terms AND-join their quoted phrases")
    func trigramMultiTermAnd() {
        #expect(AppServices.trigramMatchQuery("brut concrete")
                == "\"brut\" AND \"concrete\"")
        #expect(AppServices.trigramMatchQuery("art deco poster")
                == "\"art\" AND \"deco\" AND \"poster\"")
    }

    @Test("embedded quotes are doubled (FTS5 escaping) and never break out")
    func trigramQuotesEscaped() {
        #expect(AppServices.trigramMatchQuery("a\"bc") == "\"a\"\"bc\"")
    }

    @Test("FTS5 operators inside a term are neutralized as literal substring text")
    func trigramOperatorsNeutralized() {
        // A bare 2-char "OR" disqualifies the whole query (the <3-char rule) —
        // it never reaches FTS5 as an operator.
        #expect(AppServices.trigramMatchQuery("foo OR bar") == nil)
        // A ≥3-char literal "AND" is a QUOTED substring phrase (neutralized),
        // distinct from the real AND that joins the phrases.
        #expect(AppServices.trigramMatchQuery("foo AND bar")
                == "\"foo\" AND \"AND\" AND \"bar\"")
    }

    @Test("multibyte / unicode terms count graphemes for the 3-char rule")
    func trigramUnicode() {
        #expect(AppServices.trigramMatchQuery("café") == "\"café\"")
        // "de" (2 graphemes) is ineligible even though bytes are more.
        #expect(AppServices.trigramMatchQuery("de") == nil)
    }
}
