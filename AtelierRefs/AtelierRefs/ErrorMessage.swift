//
//  ErrorMessage.swift
//  AtelierRefs
//
//  099 · 6A (app half) — one error, one sentence.
//
//  Before P0 there were five `message(for:)` switches over `AtelierError` in this
//  app, each with a `default:` arm, and every one of those arms was a bug waiting
//  for the next case. `IngestionModel`'s said `"\(error)"`, so a case nobody had
//  thought about reached the user as
//  `persistenceFailure(detail: Optional("SQLite 11: database disk image is
//  malformed"))` — the debug description of an enum, in an alert.
//
//  P0 made `AtelierError: LocalizedError` with an exhaustive table and no
//  `default`, so a new case does not compile until someone writes its sentence,
//  ONCE, in AtelierCore. This is the app side of that: the surfaces now ask for
//  `localizedDescription` and keep only the phrasings that are genuinely theirs —
//  `IngestionModel` says "that folder", `SpaceModel` says "that space", because
//  each is telling the user about the thing they were looking at, and "Couldn't
//  find that folder" is not the same sentence as "That folder no longer exists."
//
//  The one thing this adds on top of `localizedDescription` is the log line for
//  `persistenceFailure`'s detail. AtelierCore keeps the SQLite code and message
//  OUT of its sentence on purpose (P0: "the diagnostic belongs in a log, not in an
//  alert"), and before this the two app surfaces each appended it to the alert
//  themselves. It now goes exactly one place, and it is the log.
//

import AtelierCore
import Foundation
import OSLog

nonisolated enum ErrorMessage {
    /// The user-facing sentence for any error, and the side effect that keeps the
    /// diagnostic reachable.
    ///
    /// Everything that is not an `AtelierError` still answers
    /// `localizedDescription` — an `NSError` from the filesystem already has a
    /// sentence, and inventing a second one for it was never what the switches
    /// were for.
    static func text(for error: Error) -> String {
        // `persistenceFailure`'s detail is the SQLite result code + message. It is
        // the only thing in the whole table a support conversation needs and the
        // only thing a person cannot act on, so it goes to the log and not to the
        // alert. Logged at `.public` because it names no user content — a result
        // code and SQLite's own English.
        if case AtelierError.persistenceFailure(let detail) = error,
           let detail, !detail.isEmpty {
            AppLog.model.error("persistence failure: \(detail, privacy: .public)")
        }
        return error.localizedDescription
    }

    /// The sentence for a `.notFound` whose entity matches `entity`, or `nil` when
    /// it does not — the shape both surface overrides are written in.
    ///
    /// The `entity` check is what makes an override honest. `IngestionModel`'s
    /// override used to answer "That folder no longer exists." for EVERY
    /// `.notFound`, including a missing asset, a missing space and a missing saved
    /// search. It now answers for the folder and lets Core's noun table speak for
    /// the rest, which is a sentence the surface could not have written: Core is
    /// where the entity string is turned into a word a person has seen.
    static func notFound(_ error: Error, entity: String, say sentence: String) -> String? {
        guard case AtelierError.notFound(let thrown, _) = error, thrown == entity else {
            return nil
        }
        return sentence
    }
}
