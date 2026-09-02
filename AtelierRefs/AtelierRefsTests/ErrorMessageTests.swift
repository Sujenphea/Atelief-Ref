//
//  ErrorMessageTests.swift
//  AtelierRefsTests
//
//  099 · 6A (app half) — what the surfaces say now that AtelierCore says it once.
//
//  Two things are pinned here, and they pull in opposite directions on purpose:
//
//    • the two SURVIVING overrides, each with a test, because they say something
//      Core cannot — "that folder no longer exists" and "that space no longer
//      exists" are about a thing being deleted out from under an open window,
//      where Core's "couldn't find that folder" only reports a lookup that missed;
//    • the fact that both overrides are now SCOPED to their entity. Each used to
//      answer for every `.notFound` the surface could produce, so a missing asset
//      on a board was reported as "that space no longer exists" — the model
//      telling the user, confidently, that the wrong thing had gone.
//
//  And the arm that is gone from both: `default: "\(error)"`, which put an enum's
//  debug description in front of a person for every case nobody had thought about.
//

import AtelierCore
import Foundation
import Testing

@testable import AtelierRefs

@MainActor
@Suite("One error, one sentence (099 · 6A)")
struct ErrorMessageTests {

    private static let id = UUID()

    // MARK: - The shared body

    @Test("anything that is not an AtelierError keeps its own sentence")
    func nonAtelierErrorsPassThrough() {
        let cocoa = NSError(
            domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file couldn't be opened."])
        #expect(ErrorMessage.text(for: cocoa) == "The file couldn't be opened.")
    }

    @Test("an AtelierError answers with Core's sentence, not a restatement")
    func atelierErrorsUseTheTable() {
        // The arms `IngestionModel` and `SpaceModel` used to restate in their own
        // words. Each is now one sentence, in one place, that a new case cannot
        // skip — `errorDescription` has no `default`.
        for error: AtelierError in [
            .protectedCollection(id: Self.id), .folderCycle, .invalidName,
            .invalidPlacement, .constraintViolation,
        ] {
            #expect(ErrorMessage.text(for: error) == error.localizedDescription)
            #expect(!ErrorMessage.text(for: error).isEmpty)
        }
    }

    @Test("persistenceFailure's SQLite detail does not reach the alert")
    func persistenceDetailIsNotShown() {
        // The detail is a SQLite result code and message. AtelierCore keeps it out
        // of the sentence deliberately (P0: "the diagnostic belongs in a log, not
        // in an alert"), and both app surfaces used to append it back on. It goes
        // to `AppLog.model` now, and nowhere else.
        let message = ErrorMessage.text(
            for: AtelierError.persistenceFailure(
                detail: "SQLite 11: database disk image is malformed"))
        #expect(!message.contains("SQLite"))
        #expect(!message.contains("malformed"))
        #expect(message == AtelierError.persistenceFailure(detail: "x").localizedDescription)
    }

    @Test("no sentence anywhere is an enum's debug description")
    func noDebugDescriptionsLeak() {
        // The exact shape of what the `default:` arms did: `"\(error)"` on a case
        // with a payload renders as `persistenceFailure(detail: Optional("…"))`.
        for error: AtelierError in [
            .notFound(entity: "asset", id: Self.id), .invalidName, .folderCycle,
            .persistenceFailure(detail: "boom"), .invalidSavedSearchRules(id: Self.id),
        ] {
            let text = ErrorMessage.text(for: error)
            #expect(!text.contains("("), "\(text) reads like a debug description")
            #expect(!text.contains("Optional"))
        }
    }

    // MARK: - The two surviving overrides

    @Test("IngestionModel says 'that folder no longer exists' for a missing collection")
    func ingestionFolderOverride() {
        let message = IngestionModel.message(
            for: AtelierError.notFound(entity: "collection", id: Self.id))
        #expect(message == "That folder no longer exists.")
    }

    @Test("...and NOT for a missing anything else")
    func ingestionOverrideIsScoped() {
        // It used to. A `.notFound` on an asset, a space or a saved search all came
        // back as "That folder no longer exists." Core's noun table is what can
        // speak for those, because the entity string is what it turns into a word.
        for entity in ["asset", "space", "saved_search", "tag"] {
            let error = AtelierError.notFound(entity: entity, id: Self.id)
            #expect(IngestionModel.message(for: error) == error.localizedDescription)
            #expect(IngestionModel.message(for: error) != "That folder no longer exists.")
        }
    }

    @Test("SpaceModel says 'that space no longer exists' for a missing space")
    func spaceOverride() {
        let message = SpaceModel.message(
            for: AtelierError.notFound(entity: "space", id: Self.id))
        #expect(message == "That space no longer exists.")
    }

    @Test("...and NOT for an asset or an element that has gone from the board")
    func spaceOverrideIsScoped() {
        for entity in ["asset", "space_item", "collection"] {
            let error = AtelierError.notFound(entity: entity, id: Self.id)
            #expect(SpaceModel.message(for: error) == error.localizedDescription)
            #expect(SpaceModel.message(for: error) != "That space no longer exists.")
        }
    }

    @Test("the two surfaces disagree only where they mean to")
    func surfacesAgreeElsewhere() {
        // Every case but their own `.notFound` is the same sentence on both now,
        // which is what the collapse bought: five tables became one.
        for error: AtelierError in [
            .invalidPlacement, .folderCycle, .invalidName, .constraintViolation,
            .persistenceFailure(detail: "boom"), .relevanceSortUnpageable,
        ] {
            #expect(IngestionModel.message(for: error) == SpaceModel.message(for: error))
        }
    }

    // MARK: - The override helper

    @Test("notFound(_:entity:say:) matches only its own entity, and only notFound")
    func overrideHelper() {
        #expect(ErrorMessage.notFound(
            AtelierError.notFound(entity: "space", id: Self.id),
            entity: "space", say: "gone") == "gone")
        #expect(ErrorMessage.notFound(
            AtelierError.notFound(entity: "asset", id: Self.id),
            entity: "space", say: "gone") == nil)
        #expect(ErrorMessage.notFound(
            AtelierError.folderCycle, entity: "space", say: "gone") == nil)
        #expect(ErrorMessage.notFound(
            NSError(domain: "x", code: 1), entity: "space", say: "gone") == nil)
    }
}
