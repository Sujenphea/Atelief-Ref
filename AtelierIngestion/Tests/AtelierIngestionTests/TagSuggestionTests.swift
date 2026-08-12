// AtelierIngestion — suggestion policy tests (feature 012, I3)
//
// Pure: labels in, tag names out. No Vision, no database, no fixtures on disk.
// The properties that matter are the cap, the ordering (which must be TOTAL, or
// re-running the pass churns the chips the user is looking at), and the
// normalization that has to agree with `Validation.tagName` on the Core side.

import Testing
@testable import AtelierIngestion

@Suite("TagSuggestion")
struct TagSuggestionTests {

    private func labels(_ pairs: [(String, Double)]) -> [ClassificationLabel] {
        pairs.map { ClassificationLabel(identifier: $0.0, confidence: $0.1) }
    }

    // MARK: - Ranking + cap

    @Test("the most confident labels win, capped at three")
    func ranksAndCaps() {
        let picked = TagSuggestion.select(from: labels([
            ("poster", 0.4), ("type", 0.9), ("grid", 0.7), ("paper", 0.5), ("ink", 0.2),
        ]))
        #expect(picked == ["type", "grid", "paper"])
    }

    @Test("fewer labels than the cap returns all of them")
    func belowCap() {
        #expect(TagSuggestion.select(from: labels([("type", 0.9)])) == ["type"])
        #expect(TagSuggestion.select(from: []).isEmpty)
    }

    @Test("an explicit limit is honored, and zero suggests nothing")
    func explicitLimit() {
        let input = labels([("a", 0.9), ("b", 0.8), ("c", 0.7)])
        #expect(TagSuggestion.select(from: input, limit: 2) == ["a", "b"])
        #expect(TagSuggestion.select(from: input, limit: 0).isEmpty)
        #expect(TagSuggestion.select(from: input, limit: -1).isEmpty)
    }

    /// Equal confidences must not leave the choice to sort instability: two runs
    /// over the same image would otherwise propose a different three, and the
    /// chips would shuffle under the pointer on every suggester pass.
    @Test("ties break on the name, so the result is total")
    func tiesAreTotal() {
        let forward = TagSuggestion.select(from: labels([
            ("zebra", 0.5), ("apple", 0.5), ("mango", 0.5), ("kiwi", 0.5),
        ]))
        let reversed = TagSuggestion.select(from: labels([
            ("kiwi", 0.5), ("mango", 0.5), ("apple", 0.5), ("zebra", 0.5),
        ]))
        #expect(forward == ["apple", "kiwi", "mango"])
        #expect(forward == reversed)
    }

    // MARK: - Normalization

    @Test("underscores become spaces and whitespace collapses")
    func normalizesIdentifiers() {
        #expect(TagSuggestion.normalize("plant_life") == "plant life")
        #expect(TagSuggestion.normalize("  spaced   out  ") == "spaced out")
        #expect(TagSuggestion.normalize("plain") == "plain")
    }

    /// Case is left alone on purpose: `Validation.tagName` preserves the case a
    /// person typed, and a suggestion that lowercased itself would sit beside the
    /// user's own tag as a visible duplicate.
    @Test("case is preserved, not folded")
    func preservesCase() {
        #expect(TagSuggestion.normalize("Poster") == "Poster")
    }

    @Test("labels that normalize to nothing are dropped")
    func dropsEmptyNames() {
        let picked = TagSuggestion.select(from: labels([
            ("", 0.99), ("   ", 0.98), ("_", 0.97), ("type", 0.5),
        ]))
        #expect(picked == ["type"])
    }

    /// Two identifiers that normalize onto one name are one suggestion, and the
    /// survivor is the more confident of the two.
    @Test("names that collide after normalization collapse to the best one")
    func collapsesCollisions() {
        let picked = TagSuggestion.select(from: labels([
            ("plant life", 0.6), ("plant_life", 0.8), ("type", 0.7),
        ]))
        #expect(picked == ["plant life", "type"])
    }
}
