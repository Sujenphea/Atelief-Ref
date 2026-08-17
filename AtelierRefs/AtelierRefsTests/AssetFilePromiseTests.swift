//
//  AssetFilePromiseTests.swift
//  AtelierRefsTests
//
//  011 · Cluster A (out-flow) — the file-promise plumbing. The delegate's copy +
//  failure path (9A) and the provider's dual-vending of the internal `.assetIDs`
//  payload (11A — the drag-to-rail interop guarantee) are unit-testable without a
//  live drag session, so they are.
//

import AppKit
import AtelierArchive
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AtelierRefs

// MARK: - Delegate copy + failure (9A)

@MainActor
@Suite("AssetFilePromise: delegate copy")
struct AssetFilePromiseDelegateTests {

    private func provider(blobURL: URL) -> AssetFilePromiseProvider {
        let p = AssetFilePromiseProvider(
            fileType: UTType.png.identifier, delegate: AssetFilePromiseDelegate.shared)
        p.exportItem = AssetExportItem(blobURL: blobURL, filename: "pretty.png", utType: .png)
        return p
    }

    private func tempFile(contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }

    @Test("writes the blob to the destination and reports success")
    func copySucceeds() throws {
        let bytes = Data([9, 8, 7, 6])
        let source = tempFile(contents: bytes)
        defer { try? FileManager.default.removeItem(at: source) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: dest) }

        var reported: Error?? = nil
        AssetFilePromiseDelegate.shared.filePromiseProvider(
            provider(blobURL: source), writePromiseTo: dest) { reported = .some($0) }

        let error = try #require(reported)          // completion WAS called
        #expect(error == nil)                       // …with no error
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == bytes)
    }

    @Test("a missing source blob reports an error and writes no file (5A)")
    func missingSourceFails() throws {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: dest) }

        var reported: Error?? = nil
        AssetFilePromiseDelegate.shared.filePromiseProvider(
            provider(blobURL: ghost), writePromiseTo: dest) { reported = .some($0) }

        let error = try #require(reported)
        #expect(error != nil)                                    // failure surfaced
        #expect(!FileManager.default.fileExists(atPath: dest.path))  // no zero-byte file
    }

    @Test("the promised file name is the export item's human filename")
    func fileName() {
        let p = provider(blobURL: FileManager.default.temporaryDirectory)
        #expect(AssetFilePromiseDelegate.shared.filePromiseProvider(
            p, fileNameForType: UTType.png.identifier) == "pretty.png")
    }

    @Test("a provider with no export item names a safe fallback")
    func fileNameFallback() {
        let p = AssetFilePromiseProvider(
            fileType: UTType.png.identifier, delegate: AssetFilePromiseDelegate.shared)
        #expect(AssetFilePromiseDelegate.shared.filePromiseProvider(
            p, fileNameForType: UTType.png.identifier) == "image")
    }
}

// MARK: - Provider payload vending (11A — internal-drop interop)

@MainActor
@Suite("AssetFilePromise: provider payload interop")
struct AssetFilePromiseProviderTests {

    private func makeProvider(payload: Data?) -> AssetFilePromiseProvider {
        let p = AssetFilePromiseProvider(
            fileType: UTType.png.identifier, delegate: AssetFilePromiseDelegate.shared)
        p.assetPayloadData = payload
        return p
    }

    @Test("the primary provider vends .assetIDs, round-tripping to the same payload")
    func vendsPayload() throws {
        let payload = AssetDragPayload(
            assetIDs: [UUID(), UUID()], sourceCollectionID: UUID())
        let provider = makeProvider(payload: try payload.pasteboardData())

        // writableTypes advertises the internal type…
        let pb = NSPasteboard.withUniqueName()
        #expect(provider.writableTypes(for: pb).contains(AssetDragPayload.pasteboardType))

        // …and the vended bytes decode back to the ORIGINAL payload (the drag-to-rail
        // / stack / Spaces guarantee).
        let data = try #require(
            provider.pasteboardPropertyList(forType: AssetDragPayload.pasteboardType) as? Data)
        #expect(AssetDragPayload.decode(from: data) == payload)
    }

    @Test("a non-primary provider does NOT vend .assetIDs")
    func nonPrimaryDoesNotVend() {
        let provider = makeProvider(payload: nil)
        let pb = NSPasteboard.withUniqueName()
        #expect(!provider.writableTypes(for: pb).contains(AssetDragPayload.pasteboardType))
        #expect(provider.pasteboardPropertyList(forType: AssetDragPayload.pasteboardType) == nil)
    }
}

// MARK: - Drag-pasteboard read (the 193 cross-collection fix)

/// These mutate the SHARED system drag pasteboard, so they are serialized in one
/// suite and every test clears it on the way out.
@MainActor
@Suite("AssetDragPayload: drag-pasteboard read", .serialized)
struct AssetDragPayloadDragPasteboardTests {

    private func clearDragPasteboard() { NSPasteboard(name: .drag).clearContents() }

    @Test("fromDragPasteboard decodes a payload put on the REAL drag pasteboard")
    func readsPlainPayload() throws {
        defer { clearDragPasteboard() }
        let payload = AssetDragPayload(assetIDs: [UUID()], sourceCollectionID: UUID())
        let pb = NSPasteboard(name: .drag)
        pb.clearContents()
        pb.setData(try payload.pasteboardData(), forType: AssetDragPayload.pasteboardType)
        #expect(AssetDragPayload.fromDragPasteboard() == payload)
    }

    @Test("fromDragPasteboard decodes the PROMISE-shaped drag (the live 011 shape)")
    func readsPromiseShapedDrag() throws {
        defer { clearDragPasteboard() }
        // The exact item the grid drags since 011: a file-promise provider whose
        // primary item also vends `.assetIDs`. SwiftUI's provider bridge exposes
        // NO types for this shape (the 193 regression) — the pasteboard read must.
        let blob = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        FileManager.default.createFile(atPath: blob.path, contents: Data([1]))
        defer { try? FileManager.default.removeItem(at: blob) }
        let provider = AssetFilePromiseProvider(
            fileType: UTType.png.identifier, delegate: AssetFilePromiseDelegate.shared)
        provider.exportItem = AssetExportItem(blobURL: blob, filename: "x.png", utType: .png)
        let payload = AssetDragPayload(assetIDs: [UUID(), UUID()], sourceCollectionID: UUID())
        provider.assetPayloadData = try payload.pasteboardData()

        let pb = NSPasteboard(name: .drag)
        pb.clearContents()
        pb.writeObjects([provider])
        #expect(AssetDragPayload.fromDragPasteboard() == payload)
    }

    @Test("fromDragPasteboard is nil with nothing relevant on the drag pasteboard")
    func nilWhenAbsent() {
        clearDragPasteboard()
        #expect(AssetDragPayload.fromDragPasteboard() == nil)
    }

    @Test("fromDrop prefers the drag pasteboard and completes synchronously")
    func fromDropPrefersPasteboard() throws {
        defer { clearDragPasteboard() }
        let payload = AssetDragPayload(assetIDs: [UUID()], sourceCollectionID: UUID())
        let pb = NSPasteboard(name: .drag)
        pb.clearContents()
        pb.setData(try payload.pasteboardData(), forType: AssetDragPayload.pasteboardType)

        var got: AssetDragPayload?
        let found = AssetDragPayload.fromDrop([]) { got = $0 }
        #expect(found)
        #expect(got == payload)          // synchronous on the pasteboard path
    }

    @Test("fromDrop falls back to the provider bridge when the pasteboard is bare")
    func fromDropProviderFallback() async throws {
        clearDragPasteboard()
        let payload = AssetDragPayload(assetIDs: [UUID()], sourceCollectionID: UUID())
        let data = try payload.pasteboardData()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.assetIDs.identifier, visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }

        let decoded: AssetDragPayload? = await withCheckedContinuation { cont in
            let found = AssetDragPayload.fromDrop([provider]) { cont.resume(returning: $0) }
            if !found { cont.resume(returning: nil) }
        }
        #expect(decoded == payload)
    }

    @Test("fromDrop with neither channel returns false and never completes")
    func fromDropNothing() {
        clearDragPasteboard()
        var called = false
        #expect(!AssetDragPayload.fromDrop([]) { _ in called = true })
        #expect(!called)
    }
}

// MARK: - SwiftUI .onDrop bridge (the provider FALLBACK path)

@Suite("AssetDragPayload: onDrop bridge")
struct AssetDragPayloadBridgeTests {

    @Test("loadFirst finds a .assetIDs provider and decodes the original payload")
    func decodesFromProvider() async throws {
        let payload = AssetDragPayload(assetIDs: [UUID(), UUID()], sourceCollectionID: UUID())
        let data = try payload.pasteboardData()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.assetIDs.identifier, visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }

        let decoded: AssetDragPayload? = await withCheckedContinuation { cont in
            let found = AssetDragPayload.loadFirst(from: [provider]) { cont.resume(returning: $0) }
            if !found { cont.resume(returning: nil) }
        }
        #expect(decoded == payload)
    }

    @Test("loadFirst returns false when no provider carries .assetIDs")
    func missingTypeReturnsFalse() {
        let text = NSItemProvider(object: NSString("not a payload"))
        var called = false
        let found = AssetDragPayload.loadFirst(from: [text]) { _ in called = true }
        #expect(!found)
        #expect(!called)
    }

    @Test("loadFirst returns false for an empty provider list")
    func emptyReturnsFalse() {
        #expect(!AssetDragPayload.loadFirst(from: []) { _ in })
    }
}
