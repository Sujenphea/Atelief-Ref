// AtelierCore — the `LocalizedError` prose table (6A).
//
// Two tests, and the second is the one that matters. `AtelierError`'s cases carry
// payloads, so `CaseIterable` is not available and the enumeration below is a HAND
// list. A hand list silently falls behind the moment a case is added — which is
// exactly the failure 6A exists to stop, one level up. So the second test reads
// the case count out of `AtelierError.swift` at test time and compares it to the
// list's length: adding a case fails the build (no `default` in `errorDescription`)
// AND, if someone adds the sentence but not the fixture, fails here.

import Foundation
import Testing
@testable import AtelierCore

@Suite("AtelierError: user-facing messages (6A)")
struct AtelierErrorMessageTests {

    /// The id every payload-carrying case is built with, so "the payload does not
    /// leak into the sentence" is a search for one known string.
    static let sentinel = UUID(uuidString: "DEADBEEF-1111-2222-3333-444455556666")!

    /// One value per case. Payloads are arbitrary — nothing here asserts on them
    /// except that they do not leak into the sentence.
    static let everyCase: [AtelierError] = [
        .notFound(entity: "collection", id: sentinel),
        .invalidName,
        .invalidDimensions,
        .invalidFileSize,
        .invalidBlobHash,
        .invalidPlacement,
        .missingOriginalURL(platform: .twitter),
        .protectedCollection(id: sentinel),
        .folderCycle,
        .invalidSpaceItem,
        .invalidContentKind,
        .missingPayload,
        .invalidColor,
        .invalidLinkURL,
        .emptyTweet,
        .invalidSavedSearchRules(id: sentinel),
        .relevanceSortUnpageable,
        .constraintViolation,
        .persistenceFailure(detail: "SQLite 11: database disk image is malformed"),
    ]

    @Test("every case has a user-facing sentence that is not its debug description")
    func everyCaseHasProse() {
        for error in Self.everyCase {
            let sentence = try? #require(error.errorDescription)
            let described = String(describing: error)

            #expect(error.errorDescription?.isEmpty == false, "\(described)")
            // `localizedDescription` is the surface the app actually shows; it must
            // route to `errorDescription`, not to the Foundation default
            // ("The operation couldn't be completed…").
            #expect(error.localizedDescription == error.errorDescription, "\(described)")
            #expect(error.localizedDescription != described)
            #expect(error.localizedDescription != String(reflecting: error))

            guard let sentence = sentence ?? nil else { continue }
            // Prose, not a debug dump: a real sentence, ending in punctuation, with
            // no case name, no table name, no id and no SQLite detail in it.
            #expect(sentence.count > 15, "\(described): \(sentence)")
            #expect(sentence.hasSuffix(".") || sentence.hasSuffix("!"), "\(sentence)")
            #expect(!sentence.contains("("), "\(sentence)")
            #expect(!sentence.contains("_"), "\(sentence)")
            #expect(!sentence.lowercased().contains("sqlite"), "\(sentence)")
            // No id, in either casing GRDB / Foundation might have produced.
            #expect(!sentence.contains(Self.sentinel.uuidString), "\(sentence)")
            #expect(!sentence.lowercased().contains(Self.sentinel.uuidString.lowercased()),
                    "\(sentence)")
        }
    }

    @Test("the hand-written case list covers every case declared in the source")
    func listCoversTheEnum() throws {
        // Read the enum out of the SOURCE rather than trusting the list. `#filePath`
        // is this file at compile time; the source sits two directories up and
        // across, and the test fails loudly if that ever stops being true rather
        // than silently asserting nothing.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // AtelierCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // AtelierCore (package root)
            .appendingPathComponent("Sources/AtelierCore/Services/AtelierError.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // Only the `public enum AtelierError` body — the file also holds the
        // `errorDescription` table and two noun lookups, all of them full of the
        // word `case`.
        let start = try #require(text.range(of: "public enum AtelierError: Error, Equatable {"))
        let end = try #require(text.range(of: "\n}", range: start.upperBound..<text.endIndex))
        let body = text[start.upperBound..<end.lowerBound]

        let declared = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }

        #expect(!declared.isEmpty, "the enum body parse found no cases — the anchors moved")
        #expect(
            declared.count == Self.everyCase.count,
            """
            AtelierError declares \(declared.count) cases; `everyCase` lists \
            \(Self.everyCase.count). Add the missing one to the fixture list so its \
            sentence is actually asserted:
            \(declared.joined(separator: "\n"))
            """)
    }

    @Test("notFound's sentence names a human noun, never the table")
    func notFoundNoun() {
        let id = UUID()
        #expect(AtelierError.notFound(entity: "collection", id: id).errorDescription
            == "Couldn't find that folder.")
        #expect(AtelierError.notFound(entity: "saved_search", id: id).errorDescription
            == "Couldn't find that smart collection.")
        // An entity nothing has mapped degrades to a readable word rather than
        // printing the storage name at the user.
        let unmapped = try? #require(
            AtelierError.notFound(entity: "widget_thing", id: id).errorDescription)
        #expect(unmapped == "Couldn't find that item.")
    }

    @Test("persistenceFailure keeps its SQLite detail out of the sentence")
    func persistenceDetailNotShown() throws {
        let error = AtelierError.persistenceFailure(detail: "SQLite 11: malformed")
        let sentence = try #require(error.errorDescription)
        #expect(!sentence.contains("SQLite 11"))
        #expect(!sentence.contains("malformed"))
        // The detail is still THERE for a log line — it just isn't the message.
        #expect(String(describing: error).contains("SQLite 11"))
    }
}
