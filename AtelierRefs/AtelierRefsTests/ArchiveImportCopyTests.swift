//
//  ArchiveImportCopyTests.swift
//  AtelierRefsTests
//
//  Split out of `LibraryArchiveReaderTests` when the reader moved to `AtelierArchive`
//  (092 · S6). The reader is a format concern and went with the format; `ArchiveImportCopy`
//  is the SENTENCES an import run shows a person, and it lives on
//  `ArchiveImportController` beside the run it narrates. Two different questions that
//  happened to share a file.
//

import AtelierArchive
import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Prose

@Suite("ArchiveImportCopy: what an import says (008 H7)")
struct ArchiveImportCopyTests {

    @Test("A refusal names the axis so the user can search for it")
    func refusalProse() {
        #expect(ArchiveImportCopy.message(for: .manifestTooNew(9)).contains("manifest version 9"))
        #expect(ArchiveImportCopy.message(for: .schemaTooNew("v19")).contains("v19"))
        // Both must say plainly that the library is untouched.
        #expect(ArchiveImportCopy.message(for: .manifestTooNew(9)).contains("Nothing was changed"))
        #expect(ArchiveImportCopy.message(for: .schemaTooNew("v19")).contains("Nothing was changed"))
    }

    @Test("A missing manifest is explained as an unfinished export")
    func readErrorProse() {
        #expect(ArchiveImportCopy.message(for: .missingManifest).contains("manifest.json"))
        #expect(ArchiveImportCopy.message(for: .unreadableManifest).contains("Nothing was imported"))
        #expect(ArchiveImportCopy.message(for: .refused(.manifestTooNew(2)))
            == ArchiveImportCopy.message(for: .manifestTooNew(2)))
    }

    /// A bare "succeeded" over a partial import is the outcome 004 taught this
    /// codebase not to report.
    @Test("The status line counts what happened, including what didn't")
    func statusLine() {
        var summary = ImportRunSummary(
            outcome: .succeeded, finishedAt: .now, destinationName: "Archive",
            collections: 3, assets: 4, newAssets: 4, memberships: 5)
        #expect(ArchiveImportCopy.statusLine(for: summary)
            == "Imported 4 items in 3 collections into “Archive”.")

        summary.outcome = .incomplete
        summary.skipped = 1
        summary.failed = 2
        #expect(ArchiveImportCopy.statusLine(for: summary)?
            .contains("1 item couldn’t be read") == true)
        #expect(ArchiveImportCopy.statusLine(for: summary)?
            .contains("2 items couldn’t be added") == true)

        summary.skipped = 0
        summary.failed = 0
        summary.newAssets = 1
        #expect(ArchiveImportCopy.statusLine(for: summary)?
            .contains("3 already in your library") == true)
    }

    @Test("A stopped import says what it kept; a refusal says nothing twice")
    func terminalStates() {
        let cancelled = ImportRunSummary(outcome: .cancelled, finishedAt: .now)
        #expect(ArchiveImportCopy.statusLine(for: cancelled)?.contains("kept") == true)
        // The message line carries these, in orange — a second sentence under it
        // would say the same thing twice.
        #expect(ArchiveImportCopy.statusLine(
            for: ImportRunSummary(outcome: .refused, finishedAt: .now)) == nil)
        #expect(ArchiveImportCopy.statusLine(
            for: ImportRunSummary(outcome: .failed, finishedAt: .now)) == nil)
        #expect(ArchiveImportCopy.statusLine(for: nil) == nil)
    }

    @Test("Folder-access failures are named separately")
    func folderAccessProse() {
        #expect(ArchiveImportCopy.message(for: .noFolderChosen).contains("No archive folder"))
        #expect(ArchiveImportCopy.message(for: .bookmarkUnresolvable).contains("reached"))
        #expect(ArchiveImportCopy.message(for: .accessDenied).contains("allowed to read"))
    }
}
