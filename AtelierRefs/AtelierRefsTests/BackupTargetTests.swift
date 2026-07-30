//
//  BackupTargetTests.swift
//  AtelierRefsTests
//
//  008 · H4 — vetting a picked backup folder. The containment check is the part
//  that matters: it is the only thing standing between the user and a backup that
//  copies the library into itself, and the obvious implementation (string prefix)
//  is wrong in a way that only shows up on real folder names.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("BackupTarget (008 H4)")
struct BackupTargetTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - Containment

    @Test("a folder is its own ancestor — the target cannot BE the library")
    func selfCounts() {
        let lib = url("/Volumes/Disk/Atelier")
        #expect(BackupTarget.isSelfOrDescendant(lib, of: lib))
    }

    @Test("a child and a grandchild are both inside")
    func descendantsCount() {
        let lib = url("/Volumes/Disk/Atelier")
        #expect(BackupTarget.isSelfOrDescendant(url("/Volumes/Disk/Atelier/blobs"), of: lib))
        #expect(BackupTarget.isSelfOrDescendant(
            url("/Volumes/Disk/Atelier/blobs/ab/cd"), of: lib))
    }

    @Test("a SIBLING sharing a name prefix is not inside — the string-prefix trap")
    func siblingWithSharedPrefixIsOutside() {
        // "/Volumes/Disk/Atelier2".hasPrefix("/Volumes/Disk/Atelier") is true.
        // Component comparison is what makes this a usable target instead of a
        // rejected one.
        let lib = url("/Volumes/Disk/Atelier")
        #expect(!BackupTarget.isSelfOrDescendant(url("/Volumes/Disk/Atelier2"), of: lib))
        #expect(!BackupTarget.isSelfOrDescendant(
            url("/Volumes/Disk/AtelierBackups"), of: lib))
    }

    @Test("the library's PARENT is a valid target, not a conflict")
    func ancestorIsOutside() {
        // Backups land in <target>/<library-id>/, so a parent directory never
        // recurses into the library.
        let lib = url("/Volumes/Disk/Atelier")
        #expect(!BackupTarget.isSelfOrDescendant(url("/Volumes/Disk"), of: lib))
    }

    @Test("an unrelated path is outside")
    func unrelatedIsOutside() {
        #expect(!BackupTarget.isSelfOrDescendant(
            url("/Volumes/Backup/Atelier"), of: url("/Volumes/Disk/Atelier")))
    }

    @Test("trailing slashes and dot segments don't change the answer")
    func pathsAreStandardized() {
        let lib = url("/Volumes/Disk/Atelier")
        #expect(BackupTarget.isSelfOrDescendant(url("/Volumes/Disk/Atelier/"), of: lib))
        #expect(BackupTarget.isSelfOrDescendant(
            url("/Volumes/Disk/Atelier/blobs/.."), of: lib))
        #expect(!BackupTarget.isSelfOrDescendant(
            url("/Volumes/Disk/Atelier/../Other"), of: lib))
    }

    @Test("case differences still count as inside (APFS default, and the safe way to err)")
    func comparisonIsCaseInsensitive() {
        #expect(BackupTarget.isSelfOrDescendant(
            url("/Volumes/Disk/ATELIER/blobs"), of: url("/Volumes/Disk/Atelier")))
    }

    @Test("a deeper path that diverges midway is outside")
    func divergentDeepPathIsOutside() {
        #expect(!BackupTarget.isSelfOrDescendant(
            url("/Volumes/Disk/Other/Atelier/blobs"), of: url("/Volumes/Disk/Atelier")))
    }

    // MARK: - Rejection

    @Test("choosing the library itself, or anything in it, is rejected")
    func insideLibraryRejected() {
        let lib = url("/Volumes/Disk/Atelier")
        #expect(BackupTarget.rejection(choosing: lib, libraryRoot: lib) == .insideLibrary)
        #expect(BackupTarget.rejection(
            choosing: url("/Volumes/Disk/Atelier/backups"), libraryRoot: lib) == .insideLibrary)
    }

    @Test("a folder on another volume is accepted")
    func outsideLibraryAccepted() {
        #expect(BackupTarget.rejection(
            choosing: url("/Volumes/Backup/atelier"),
            libraryRoot: url("/Volumes/Disk/Atelier")) == nil)
    }

    @Test("with no library open, a choice cannot be claimed to conflict")
    func unknownLibraryAcceptsAnything() {
        #expect(BackupTarget.rejection(
            choosing: url("/Volumes/Backup/atelier"), libraryRoot: nil) == nil)
    }

    // MARK: - Words

    @Test("every unreachable-target reason gets its own next action")
    func errorMessagesAreDistinct() {
        let all: [FolderAccessError] = [.noFolderChosen, .bookmarkUnresolvable, .accessDenied]
        let messages = all.map(BackupTarget.message(for:))
        #expect(messages.allSatisfy { !$0.isEmpty })
        // Distinct because each names a DIFFERENT remedy — collapsing them would
        // undo the reason `FolderAccessError` has three cases.
        #expect(Set(messages).count == all.count)
    }

    @Test("the unreachable-drive message tells the user to reconnect it")
    func unresolvableMessageNamesTheRemedy() {
        let message = BackupTarget.message(for: .bookmarkUnresolvable)
        #expect(message.localizedCaseInsensitiveContains("reconnect"))
    }

    @Test("the inside-the-library message says what to do instead")
    func rejectionMessageNamesTheRemedy() {
        let message = BackupTarget.message(for: .insideLibrary)
        #expect(!message.isEmpty)
        #expect(message.localizedCaseInsensitiveContains("another drive"))
    }

    @Test("the standing explainer distinguishes backups from snapshots")
    func explainerContrastsWithSnapshots() {
        // The whole point of the feature: snapshots don't survive losing the Mac.
        #expect(BackupTarget.explainer.localizedCaseInsensitiveContains("snapshot"))
    }
}
