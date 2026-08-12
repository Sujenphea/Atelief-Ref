// AtelierIngestion — the suggestion policy (feature 012, I3)
//
// The pure half of suggested tags: given whatever a classifier believed about an
// image, decide which of it is worth putting in front of a person. No Vision, no
// database, no I/O — a list in, a list of tag names out — so the policy that
// decides what the user sees is fixture-testable without a model.
//
// The policy is deliberately severe. 012's risk note is the design brief here:
// "Vision classification labels are generic ('poster', 'text') — tune threshold
// high; suggestion UX tolerates misses far better than noise." A suggestion the
// user has to dismiss costs them an action and a little trust; a suggestion that
// never appears costs them nothing they can see. So the confidence gate lives in
// the adapter at high precision, and this layer caps what survives at three.

import Foundation

/// One thing a classifier believed about an image — the classifier-agnostic
/// currency between ``ImageClassifying`` and the policy below.
public struct ClassificationLabel: Sendable, Equatable, Hashable {
    /// The classifier's own identifier for the label (Vision's taxonomy uses
    /// lowercase, underscore-joined identifiers such as `plant_life`).
    public let identifier: String
    /// How confident the classifier is, `0...1`. Used for ORDER only — the
    /// keep/drop threshold is applied by the adapter, which has the model's
    /// precision-recall curve and can therefore judge a confidence number that is
    /// meaningless in isolation.
    public let confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// Turns classifier labels into the tag names to suggest (012 · I3).
public enum TagSuggestion {
    /// The suggester version stamped on every asset this policy has looked at
    /// (`asset_analysis.suggest_version`). Bump it when the model generation OR
    /// anything below changes, and the next backfill re-suggests the library via
    /// a `WHERE suggest_version < …` scan.
    ///
    /// A bump is safe by construction: `recordSuggestions` drops every name the
    /// user has dismissed, and a dismissal never expires. That is the property
    /// this whole feature's memory exists to provide — without it, bumping this
    /// constant would resurrect every refused tag in the library at once.
    public static let version = 1

    /// How many suggestions one asset may carry at a time (012's open question 3,
    /// answered: top 3). Past three the sidebar reads as a wall of guesses rather
    /// than an offer, and the marginal label is the least confident one.
    public static let maxSuggestions = 3

    /// The tag names to suggest for an image, most-confident first, at most
    /// `limit` of them.
    ///
    /// Ordering is by confidence descending, ties broken on the normalized name
    /// so the result is TOTAL — two runs over the same labels must not propose a
    /// different three, or a re-suggestion pass would churn chips the user is
    /// looking at. Normalized names that collide (`plant_life` and `plant life`)
    /// collapse to the first, most-confident occurrence.
    public static func select(
        from labels: [ClassificationLabel], limit: Int = maxSuggestions
    ) -> [String] {
        guard limit > 0 else { return [] }

        let named: [(name: String, confidence: Double)] = labels.compactMap { label in
            let name = normalize(label.identifier)
            return name.isEmpty ? nil : (name: name, confidence: label.confidence)
        }
        let ranked = named.sorted { lhs, rhs in
            lhs.confidence == rhs.confidence
                ? lhs.name < rhs.name
                : lhs.confidence > rhs.confidence
        }

        var seen = Set<String>()
        var picked: [String] = []
        for candidate in ranked where seen.insert(candidate.name).inserted {
            picked.append(candidate.name)
            if picked.count == limit { break }
        }
        return picked
    }

    /// A classifier identifier as a tag name: underscores become spaces and the
    /// result is trimmed and whitespace-collapsed.
    ///
    /// Case is left exactly as the classifier produced it (Vision's taxonomy is
    /// already lowercase). Lowercasing here would be a second normalization rule
    /// competing with `Validation.tagName`, which preserves the case a person
    /// typed — and the two must agree, because a suggestion whose name does not
    /// match the tag the user already has is a duplicate chip.
    static func normalize(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
