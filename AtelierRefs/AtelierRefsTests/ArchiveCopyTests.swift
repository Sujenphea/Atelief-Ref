//
//  ArchiveCopyTests.swift
//  AtelierRefsTests
//
//  Split out of `LibraryArchiveTests` when the manifest moved to `AtelierArchive`
//  (092 · S6), for the same reason `ArchiveImportCopyTests` was: `ArchiveCopy` is the
//  words an export run shows a person and belongs beside the controller that shows them,
//  while the format itself went with the format.
//

import AtelierArchive
import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Words

@Suite("LibraryArchive: the words a run reports (008 H6)")
struct ArchiveCopyTests {

    @Test("The suggested folder name is dated, so two archives are tellable apart")
    func suggestedName() {
        let date = Date(timeIntervalSince1970: 1_767_323_045)
        #expect(ArchiveCopy.suggestedName(for: date).hasPrefix("Atelier Archive 2026-01-"))
    }

    @Test("A clean run counts what it wrote")
    func successLine() {
        let summary = ArchiveRunSummary(
            outcome: .succeeded, finishedAt: Date(), collections: 3, assets: 7, files: 9)
        #expect(ArchiveCopy.statusLine(for: summary) == "Archived 7 items in 3 collections.")
    }

    @Test("A run that couldn't copy everything says so rather than claiming success")
    func incompleteLine() {
        let summary = ArchiveRunSummary(
            outcome: .incomplete, finishedAt: Date(), collections: 1, assets: 1,
            files: 0, skipped: 1)
        #expect(ArchiveCopy.statusLine(for: summary)
            == "Archived 1 item in 1 collection. 1 file couldn't be copied.")
    }

    @Test("A cancelled run says the folder is incomplete, not that it failed")
    func cancelledLine() {
        let summary = ArchiveRunSummary(outcome: .cancelled, finishedAt: Date())
        #expect(ArchiveCopy.statusLine(for: summary)?.contains("stopped") == true)
    }

    /// A failure already shows its own message in orange; a second line
    /// restating it would be noise.
    @Test("A failed run has no status line — its message carries the words")
    func failedLine() {
        #expect(ArchiveCopy.statusLine(for: .failure("nope")) == nil)
        #expect(ArchiveCopy.statusLine(for: nil) == nil)
    }

    @Test("Every folder-access failure maps to its own sentence")
    func folderMessages() {
        let messages = [FolderAccessError.noFolderChosen, .bookmarkUnresolvable, .accessDenied]
            .map(ArchiveCopy.message(for:))
        #expect(Set(messages).count == 3)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }
}
