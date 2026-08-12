// AtelierExport — originals folder writer tests (011 · A2)
//
// Real temp directories and real files, for `SiteExportWriterTests`' reason: the
// whole point of this layer is what ends up ON DISK, so a mocked FileManager
// would test the mock. Fixtures are a few bytes each, which is also the shape a
// 40 GB run takes — the writer streams and never accumulates, so 3 files and
// 3000 exercise the same code.

import Foundation
import Testing
@testable import AtelierExport

@Suite("Originals: folder writer")
struct AssetFolderWriterTests {

    // MARK: - Harness

    /// A scratch directory removed after `body`.
    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A real file with `bytes` of `byte`.
    private func makeFile(_ url: URL, bytes: Int = 8, byte: UInt8 = 0x41) {
        FileManager.default.createFile(
            atPath: url.path, contents: Data(repeating: byte, count: bytes))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - The happy path

    @Test("Copies each original into the folder flat, under its export name")
    func writesFolder() throws {
        try withTempDirectory { temp in
            let a = temp.appendingPathComponent("blob-a")
            let b = temp.appendingPathComponent("blob-b")
            makeFile(a)
            makeFile(b)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try AssetFolderWriter.write(
                files: [
                    ExportFile(source: a, filename: "nike-ad-3f2a91c4.jpg"),
                    ExportFile(source: b, filename: "clip-c40f9a2e.mp4"),
                ],
                to: out)

            #expect(result.copied == 2)
            #expect(result.skipped.isEmpty)
            #expect(result.root == out)
            // Flat: no `assets/` subfolder, unlike the static-site writer.
            #expect(exists(out.appendingPathComponent("nike-ad-3f2a91c4.jpg")))
            #expect(exists(out.appendingPathComponent("clip-c40f9a2e.mp4")))
            #expect(!exists(out.appendingPathComponent("assets")))
        }
    }

    @Test("Creates the destination folder, including missing parents")
    func createsDestination() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("deep/nested/out", isDirectory: true)

            let result = try AssetFolderWriter.write(
                files: [ExportFile(source: source, filename: "a.png")], to: out)

            #expect(result.copied == 1)
            #expect(exists(out.appendingPathComponent("a.png")))
        }
    }

    @Test("Copies bytes verbatim — the original is never re-encoded")
    func copiesBytesVerbatim() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source, bytes: 64, byte: 0x5A)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            try AssetFolderWriter.write(
                files: [ExportFile(source: source, filename: "a.png")], to: out)

            let copied = try Data(contentsOf: out.appendingPathComponent("a.png"))
            #expect(copied == Data(repeating: 0x5A, count: 64))
        }
    }

    // MARK: - Empty

    @Test("An empty file list is a hard failure, not an empty folder")
    func emptyThrows() throws {
        try withTempDirectory { temp in
            let out = temp.appendingPathComponent("out", isDirectory: true)
            #expect(throws: ExportError.noPages) {
                try AssetFolderWriter.write(files: [], to: out)
            }
            // Nothing was created on the way to the throw.
            #expect(!exists(out))
        }
    }

    // MARK: - Soft skips (one bad ref never sinks the export)

    @Test("A source gone from disk is a reported skip; its neighbours still land")
    func missingSourceSkips() throws {
        try withTempDirectory { temp in
            let present = temp.appendingPathComponent("blob-present")
            makeFile(present)
            let gone = temp.appendingPathComponent("blob-reaped")   // never created
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try AssetFolderWriter.write(
                files: [
                    ExportFile(source: gone, filename: "reaped.png"),
                    ExportFile(source: present, filename: "here.png"),
                ],
                to: out)

            #expect(result.copied == 1)
            #expect(result.skipped == [
                ExportSkip(filename: "reaped.png", reason: .missingSource)
            ])
            #expect(exists(out.appendingPathComponent("here.png")))
            #expect(!exists(out.appendingPathComponent("reaped.png")))
        }
    }

    @Test("Every source missing still succeeds — all skips, no throw")
    func allMissingStillSucceeds() throws {
        try withTempDirectory { temp in
            let out = temp.appendingPathComponent("out", isDirectory: true)
            let result = try AssetFolderWriter.write(
                files: [
                    ExportFile(source: temp.appendingPathComponent("x"), filename: "x.png"),
                    ExportFile(source: temp.appendingPathComponent("y"), filename: "y.png"),
                ],
                to: out)

            #expect(result.copied == 0)
            #expect(result.skipped.count == 2)
        }
    }

    // MARK: - Duplicates

    @Test("One blob backing two selected rows costs one file, counted once")
    func duplicateNameCopiedOnce() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try AssetFolderWriter.write(
                files: [
                    ExportFile(source: source, filename: "same-ab12cd34.png"),
                    ExportFile(source: source, filename: "same-ab12cd34.png"),
                ],
                to: out)

            #expect(result.copied == 1)
            #expect(result.skipped.isEmpty)
        }
    }

    // MARK: - Re-export

    @Test("A re-export refreshes the names it writes and leaves everything else alone")
    func reExportRefreshesOnlyItsOwn() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source, bytes: 4, byte: 0x01)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            // A stale copy of the export's own name, plus a file that is the
            // user's and none of the export's business.
            makeFile(out.appendingPathComponent("a.png"), bytes: 99, byte: 0xFF)
            makeFile(out.appendingPathComponent("my-taxes.pdf"), bytes: 7)

            let result = try AssetFolderWriter.write(
                files: [ExportFile(source: source, filename: "a.png")], to: out)

            #expect(result.copied == 1)
            // The name it owns was refreshed to the current bytes...
            let refreshed = try Data(contentsOf: out.appendingPathComponent("a.png"))
            #expect(refreshed == Data(repeating: 0x01, count: 4))
            // ...and the bystander is untouched.
            #expect(exists(out.appendingPathComponent("my-taxes.pdf")))
        }
    }

    // MARK: - Cancellation

    @Test("Cancel before the first copy throws and writes nothing")
    func cancelUpFront() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            #expect(throws: CancellationError.self) {
                try AssetFolderWriter.write(
                    files: [ExportFile(source: source, filename: "a.png")],
                    to: out, isCancelled: { true })
            }
            #expect(!exists(out.appendingPathComponent("a.png")))
        }
    }

    @Test("Cancel mid-run stops copying; cleanup is the caller's job")
    func cancelMidRun() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            var seen = 0
            #expect(throws: CancellationError.self) {
                try AssetFolderWriter.write(
                    files: (0..<5).map {
                        ExportFile(source: source, filename: "file-\($0).png")
                    },
                    to: out,
                    isCancelled: {
                        seen += 1
                        return seen > 2       // first two copies run, the third cancels
                    })
            }
            #expect(exists(out.appendingPathComponent("file-0.png")))
            #expect(exists(out.appendingPathComponent("file-1.png")))
            #expect(!exists(out.appendingPathComponent("file-2.png")))
        }
    }

    // MARK: - Copy failure (the other half of the error contract)

    @Test("A copy the filesystem refuses is a reported skip, not a throw")
    func copyFailureSkips() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            // Make the destination unwritable — the deterministic stand-in for a
            // full disk or a permissions problem, which is the branch that
            // otherwise never runs.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: out.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: out.path)
            }

            let result = try AssetFolderWriter.write(
                files: [ExportFile(source: source, filename: "a.png")], to: out)

            #expect(result.copied == 0)
            #expect(result.skipped.count == 1)
            #expect(result.skipped.first?.filename == "a.png")
            // The reason must be `copyFailed` and must carry the message — not
            // `missingSource`, which would misdescribe a present-but-uncopyable file.
            switch result.skipped.first?.reason {
            case .copyFailed(let message): #expect(!message.isEmpty)
            default: Issue.record("expected .copyFailed, got \(String(describing: result.skipped.first?.reason))")
            }
        }
    }

    // MARK: - Unsafe names (011 · A2 — the writer checks its own invariant)

    @Test("A traversal name is refused and never written outside the destination")
    func traversalNameRefused() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            let escapee = temp.appendingPathComponent("evil.png")

            let result = try AssetFolderWriter.write(
                files: [ExportFile(source: source, filename: "../evil.png")], to: out)

            #expect(result.copied == 0)
            #expect(result.skipped == [
                ExportSkip(filename: "../evil.png", reason: .unsafeName)
            ])
            // The whole point: nothing landed in the parent directory.
            #expect(!exists(escapee))
        }
    }

    @Test("An absolute path as a filename is refused")
    func absoluteNameRefused() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)
            let absolute = temp.appendingPathComponent("absolute.png")

            let result = try AssetFolderWriter.write(
                files: [ExportFile(source: source, filename: absolute.path)], to: out)

            #expect(result.copied == 0)
            #expect(result.skipped.first?.reason == .unsafeName)
            #expect(!exists(absolute))
        }
    }

    @Test("An unsafe name does not stop the files around it")
    func unsafeNameDoesNotSinkTheExport() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            let result = try AssetFolderWriter.write(
                files: [
                    ExportFile(source: source, filename: "../escape.png"),
                    ExportFile(source: source, filename: "fine.png"),
                ],
                to: out)

            #expect(result.copied == 1)
            #expect(result.skipped.count == 1)
            #expect(exists(out.appendingPathComponent("fine.png")))
        }
    }

    @Test("hasSafeName accepts ordinary export names and rejects every escape shape")
    func safeNameMatrix() {
        let file = { (name: String) in ExportFile(source: URL(fileURLWithPath: "/x"), filename: name) }

        // What `AssetExport.filename` actually produces, including a backslash —
        // an ordinary character on macOS, not a separator.
        for good in ["hero-ab12cd34.png", "hero-ab12cd34-2.png", "a b c.mp4",
                     "Ünïcode ✳️.png", "no-extension", "back\\slash.png", "...leading"] {
            #expect(file(good).hasSafeName, "expected \(good) to be accepted")
        }
        for bad in ["", ".", "..", "/", "a/b.png", "../evil.png", "/abs/evil.png",
                    "sub/dir/x.png", "trailing/", "nul\0byte.png"] {
            #expect(!file(bad).hasSafeName, "expected \(bad) to be rejected")
        }
    }

    // MARK: - Progress

    @Test("Progress rises strictly, one tick per file plus a final 1")
    func progressReachesOne() throws {
        try withTempDirectory { temp in
            let source = temp.appendingPathComponent("blob")
            makeFile(source)
            let out = temp.appendingPathComponent("out", isDirectory: true)

            var ticks: [Double] = []
            try AssetFolderWriter.write(
                files: (0..<4).map { ExportFile(source: source, filename: "f-\($0).png") },
                to: out, onProgress: { ticks.append($0) })

            // Pinned exactly rather than "sorted" — a non-strict sort check passes
            // for an all-identical sequence, so it proved almost nothing.
            #expect(ticks == [0.25, 0.5, 0.75, 1, 1])
            #expect(ticks.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    @Test("A skipped file still advances progress")
    func skipAdvancesProgress() throws {
        try withTempDirectory { temp in
            let out = temp.appendingPathComponent("out", isDirectory: true)
            var ticks: [Double] = []
            try AssetFolderWriter.write(
                files: [ExportFile(source: temp.appendingPathComponent("gone"), filename: "g.png")],
                to: out, onProgress: { ticks.append($0) })

            // One tick for the skipped file, one for the tail. (`ticks.last == 1`
            // already implied non-emptiness, so that assertion is gone.)
            #expect(ticks == [1, 1])
        }
    }
}
