//
//  BrowseFailureTests.swift
//  AtelierBrowseTests
//
//  093 § 7 asked for this by name and 098 · finding 9 recorded that it had never run: the
//  typed App Group failure → sentence mapping is the entire user-facing consequence of the
//  decision (092 · S1 · decision 3) to make a missing container a FATAL error rather than
//  a silent fallback to some other directory. When it fires, the sentence IS the app.
//
//  Every case the mapping distinguishes is here, including the two `default` arms — which
//  are the ones worth pinning, because a `default` that quietly absorbs a case somebody
//  meant to name is invisible until a person is holding the broken phone.
//

import Foundation
import Testing

import AtelierCore
import AtelierLibraryPaths
@testable import AtelierBrowse

@Suite("BrowseFailure (093 §7)")
struct BrowseFailureTests {

    @Test("a missing App Group key blames the BUILD, because that is what is wrong")
    func appGroupIdentifierMissing() {
        // The one failure a user could usefully report verbatim: the bundle carries no
        // `AtelierAppGroupIdentifier`, which is a provisioning mistake and not their
        // library being gone.
        #expect(BrowseFailure.message(
            for: LibraryLocationError.appGroupIdentifierMissing(key: "AtelierAppGroupIdentifier"))
            == "This build is missing its App Group. The library can't be opened.")
        // The payload does not reach the sentence — a key name on a phone screen is noise.
        #expect(BrowseFailure.message(
            for: LibraryLocationError.appGroupIdentifierMissing(key: "Anything"))
            == BrowseFailure.message(
                for: LibraryLocationError.appGroupIdentifierMissing(key: "Other")))
    }

    @Test("an ungranted container is a different sentence from a missing key")
    func appGroupContainerUnavailable() {
        // Spelled right, entitlement does not grant it. Different fix, different sentence.
        let message = BrowseFailure.message(
            for: LibraryLocationError.appGroupContainerUnavailable(identifier: "group.x"))
        #expect(message
            == "The App Group container isn't available. The library can't be opened.")
        #expect(message != BrowseFailure.message(
            for: LibraryLocationError.appGroupIdentifierMissing(key: "k")))
    }

    @Test("a not-found is a collection, because it is the only one browse can reach")
    func notFound() {
        #expect(BrowseFailure.message(
            for: AtelierError.notFound(entity: "collection", id: UUID()))
            == "That collection is no longer in the library.")
        // The entity is not read: `feed(for:)` is the only read that throws this, and a
        // missing ITEM comes back as `nil` precisely so the two get different treatment.
        #expect(BrowseFailure.message(for: AtelierError.notFound(entity: "asset", id: UUID()))
            == "That collection is no longer in the library.")
    }

    @Test("every other AtelierError is a read that failed, and says so")
    func otherServiceErrors() {
        // Browse makes no writes (091 · D1), so a validation case arriving here means the
        // READ failed — a collapsed GRDB error, most likely. Exhaustive over the arm
        // rather than over the enum: what is pinned is that none of these is allowed to
        // fall through to the "couldn't be OPENED" sentence, which would send a user
        // looking at their provisioning for a corrupt row.
        let read = "The library couldn't be read."
        #expect(BrowseFailure.message(for: AtelierError.invalidName) == read)
        #expect(BrowseFailure.message(for: AtelierError.invalidDimensions) == read)
        #expect(BrowseFailure.message(for: AtelierError.invalidBlobHash) == read)
        #expect(BrowseFailure.message(for: AtelierError.folderCycle) == read)
        #expect(BrowseFailure.message(for: AtelierError.protectedCollection(id: UUID())) == read)
        #expect(BrowseFailure.message(for: AtelierError.missingOriginalURL(platform: .web))
            == read)
    }

    @Test("a library that is not open is the general sentence")
    func libraryUnavailable() {
        // What every read throws before `bootstrap()` has succeeded. The phase is already
        // showing the real reason, so this one carries nothing new.
        #expect(BrowseFailure.message(for: BrowseStore.LibraryUnavailable())
            == "The library couldn't be opened.")
    }

    @Test("an unrecognised error does not leak its type name onto the screen")
    func unknownError() {
        struct Whatever: Error {}
        #expect(BrowseFailure.message(for: Whatever()) == "The library couldn't be opened.")
        // A `CocoaError` from opening the pool — a full disk, a permissions failure — is
        // the realistic one, and it is deliberately the same sentence: the phone cannot
        // tell those apart without asking questions it has no way to ask.
        #expect(BrowseFailure.message(for: CocoaError(.fileNoSuchFile))
            == "The library couldn't be opened.")
    }

    @Test("no sentence is empty, and every one of them ends in a full stop")
    func sentencesAreSentences() {
        struct Whatever: Error {}
        let errors: [Error] = [
            LibraryLocationError.appGroupIdentifierMissing(key: "k"),
            LibraryLocationError.appGroupContainerUnavailable(identifier: "g"),
            AtelierError.notFound(entity: "collection", id: UUID()),
            AtelierError.invalidName,
            BrowseStore.LibraryUnavailable(),
            Whatever(),
        ]
        for error in errors {
            let message = BrowseFailure.message(for: error)
            #expect(!message.isEmpty)
            #expect(message.hasSuffix("."))
        }
    }
}
