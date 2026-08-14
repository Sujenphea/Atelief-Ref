// AtelierIngestion tests — the Library's subdirectory names (003 storage layout;
// 092 · S2 for `inbox`).
//
// `LibraryLayout` is pure path arithmetic and must stay that way: the media store
// creates directories on demand, and a layout that created them as a side effect of
// being asked a question would scatter empty folders through every scratch library a
// test ever builds. `inbox` is the newest of these names and the only one this type
// does not spell itself — it delegates to `AtelierCapture.InboxLayout`, because the
// iOS share extension writes that directory and cannot link this package.

import Foundation
import Testing

import AtelierCapture
@testable import AtelierIngestion

@Suite("LibraryLayout subdirectories (092 S2)")
struct LibraryLayoutTests {

    private let root = URL(fileURLWithPath: "/tmp/atelier-layout-test")

    @Test("the inbox is <root>/inbox/")
    func inboxSitsUnderTheRoot() {
        let layout = LibraryLayout(root: root)

        #expect(layout.inbox == root.appendingPathComponent("inbox", isDirectory: true))
        #expect(layout.inbox.lastPathComponent == InboxLayout.directoryName)
    }

    @Test("the inbox is a sibling of the other stores, not nested in one")
    func inboxIsASibling() {
        let layout = LibraryLayout(root: root)

        #expect(layout.inbox.deletingLastPathComponent() == layout.blobs.deletingLastPathComponent())
        #expect(layout.inbox != layout.cache)
        #expect(layout.inbox != layout.blobs)
        #expect(layout.inbox != layout.thumbnails)
        #expect(layout.inbox != layout.snapshots)
    }

    @Test("the writer's view of the inbox is the same directory the layout names")
    func theWriterAndTheLayoutAgree() {
        // The point of the delegation: one authority reached from both sides of a
        // package boundary the share extension cannot cross in the other direction.
        #expect(InboxLayout(libraryRoot: root).directory == LibraryLayout(root: root).inbox)
    }

    @Test("asking for a subdirectory creates nothing")
    func layoutCreatesNothing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryLayoutTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = LibraryLayout(root: base)

        _ = (layout.inbox, layout.blobs, layout.thumbnails, layout.cache, layout.snapshots)

        #expect(!FileManager.default.fileExists(atPath: base.path))
        #expect(!FileManager.default.fileExists(atPath: layout.inbox.path))
    }
}
