//
//  HostToolKeyTests.swift
//  CanvasRendererTests
//
//  The tool keys (V / F / T) as `keyDown` on the canvas.
//
//  They used to be unmodified SwiftUI `keyboardShortcut`s in the app. The last suite
//  here is why they are not: a key equivalent is dispatched BEFORE `keyDown` reaches
//  the first responder, and it cannot see that the responder is an `NSTextView`. That
//  is a platform behaviour this design now depends on, so it is measured rather than
//  assumed.
//

import AppKit
import SwiftUI
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Canvas tool keys")
struct HostToolKeyTests {
    private final class TextProvider: TileProvider, @unchecked Sendable {
        var tiles: [Tile] = [Tile(id: 0, x: 0, y: 0, w: 300, h: 40, z: 0)]
        func content(for tile: Tile) -> TileContent {
            .text(TextStyle(string: "hello", fontSize: 16,
                            color: RGBAColor(red: 1, green: 1, blue: 1)))
        }
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private func makeHost() -> CanvasHostView {
        let host = CanvasHostView(
            provider: TextProvider(), images: NoImages(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        host.framesContentWhenReady = false
        host.layout()
        return host
    }

    private func keyDown(_ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    // MARK: - The mapping

    @Test("the three tool keys, and nothing else")
    func mapping() {
        #expect(CanvasHostView.toolShortcut(characters: "v", modifiers: []) == .select)
        #expect(CanvasHostView.toolShortcut(characters: "f", modifiers: []) == .frame)
        #expect(CanvasHostView.toolShortcut(characters: "t", modifiers: []) == .text)
        #expect(CanvasHostView.toolShortcut(characters: "V", modifiers: .shift) == .select)
        #expect(CanvasHostView.toolShortcut(characters: "a", modifiers: []) == nil)
        #expect(CanvasHostView.toolShortcut(characters: nil, modifiers: []) == nil)
        #expect(CanvasHostView.toolShortcut(characters: "", modifiers: []) == nil)
    }

    @Test("a modifier disqualifies it — ⌘V must still paste")
    func modifiersAreNotToolKeys() {
        #expect(CanvasHostView.toolShortcut(characters: "v", modifiers: .command) == nil)
        #expect(CanvasHostView.toolShortcut(characters: "t", modifiers: .option) == nil)
        #expect(CanvasHostView.toolShortcut(characters: "f", modifiers: .control) == nil)
        #expect(CanvasHostView.toolShortcut(
            characters: "v", modifiers: [.command, .shift]) == nil)
    }

    // MARK: - Routing

    @Test("a bare tool key is reported and consumed")
    func keyDownReportsTheTool() {
        let host = makeHost()
        var tools: [CanvasTool] = []
        host.onSelectTool = { tools.append($0) }

        host.keyDown(with: keyDown("t"))
        host.keyDown(with: keyDown("f"))
        host.keyDown(with: keyDown("v"))

        #expect(tools == [.text, .frame, .select])
    }

    @Test("an edit in progress owns the keyboard — no tool key fires")
    func editingSuppressesToolKeys() {
        let host = makeHost()
        var tools: [CanvasTool] = []
        host.beginEditingText(tileID: 0, isNewlyCreated: false)
        host.onSelectTool = { tools.append($0) }

        host.keyDown(with: keyDown("t"))

        #expect(tools.isEmpty)
        #expect(host.editingTileID == 0)   // …and it did not disturb the edit
    }

    @Test("⌫ still deletes the selection — the tool keys did not displace it")
    func deleteStillWins() {
        let host = makeHost()
        var deleted: [Set<Int>] = []
        var tools: [CanvasTool] = []
        host.onDeleteTiles = { deleted.append($0) }
        host.onSelectTool = { tools.append($0) }
        host.selectedTileIDs = [0]

        host.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!)

        #expect(deleted == [[0]])
        #expect(tools.isEmpty)
    }
}

// MARK: - Why the tool keys are not `keyboardShortcut`s

@MainActor
private final class ShortcutLog: ObservableObject {
    var fired: [String] = []
}

private struct HostedTextView: NSViewRepresentable {
    let onMake: (NSTextView) -> Void
    func makeNSView(context: Context) -> NSTextView {
        let view = CanvasEditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.isRichText = false
        view.string = ""
        onMake(view)
        return view
    }
    func updateNSView(_ nsView: NSTextView, context: Context) {}
}

@MainActor
private struct ShortcutRoot: View {
    let log: ShortcutLog
    let onMake: (NSTextView) -> Void
    var body: some View {
        ZStack {
            HostedTextView(onMake: onMake).frame(width: 200, height: 40)
            ZStack {
                Button("") { log.fired.append("v") }.keyboardShortcut("v", modifiers: [])
                Button("") { log.fired.append("t") }.keyboardShortcut("t", modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }
}

@MainActor
@Suite("An unmodified keyboardShortcut beats a focused NSTextView")
struct ShortcutVsTextViewTests {
    /// The whole reason ``CanvasHostView/onSelectTool`` exists. If this ever starts
    /// failing — i.e. SwiftUI learns to stand down for a focused AppKit text view —
    /// the app could go back to plain shortcuts. Until then it cannot.
    @Test("a plain letter is claimed by the shortcut and never reaches the text view")
    func plainShortcutSwallowsTyping() {
        let log = ShortcutLog()
        var textView: NSTextView?
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(
            rootView: ShortcutRoot(log: log, onMake: { textView = $0 }))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let textView else {
            Issue.record("the representable never made its text view")
            return
        }
        #expect(window.makeFirstResponder(textView))

        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "t", charactersIgnoringModifiers: "t",
            isARepeat: false, keyCode: 17)!

        // Exactly what AppKit does with a key-down before offering it to the responder.
        let claimed = window.performKeyEquivalent(with: event)
        if !claimed { window.firstResponder?.keyDown(with: event) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(claimed)                    // the button took it…
        #expect(log.fired == ["t"])         // …and ran its action…
        #expect(textView.string.isEmpty)    // …and the user's keystroke was lost
    }
}
