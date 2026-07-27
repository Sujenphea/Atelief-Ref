import AppKit
import CoreGraphics
import Testing
@testable import CanvasRenderer

/// The canvas paste seam (059 · SP4): ⌘V through the responder chain maps to the
/// world point at the VIEWPORT CENTRE (via the shared transform) and hands it to
/// the app's `onPaste`. No window needed — the host's default transform is the
/// identity, so the centre world point equals the bounds centre.
@MainActor
@Suite("Canvas paste seam (059 · SP4)")
struct PasteSeamTests {
    private struct FixedProvider: TileProvider { let tiles: [Tile] }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private func makeHost(width: CGFloat, height: CGFloat) -> CanvasHostView {
        CanvasHostView(
            provider: FixedProvider(tiles: []), images: NoImages(),
            frame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test("paste maps to the viewport-centre world point and invokes onPaste")
    func pasteInvokesWithCentre() {
        let host = makeHost(width: 400, height: 300)
        var captured: CGPoint?
        host.onPaste = { _, world in captured = world; return true }
        host.paste(nil)
        // Default transform is identity (scale 1, no translation) → world == centre.
        #expect(captured == CGPoint(x: 200, y: 150))
    }

    @Test("paste with no handler is a silent no-op (no crash)")
    func pasteNoHandlerNoOp() {
        let host = makeHost(width: 400, height: 300)
        host.onPaste = nil
        host.paste(nil) // must return early without touching the pasteboard
    }

    @Test("Paste menu item is enabled only when a handler is wired")
    func pasteValidation() {
        let host = makeHost(width: 100, height: 100)
        let item = NSMenuItem(title: "Paste", action: #selector(CanvasHostView.paste(_:)), keyEquivalent: "v")
        host.onPaste = nil
        #expect(host.validateUserInterfaceItem(item) == false)
        host.onPaste = { _, _ in true }
        #expect(host.validateUserInterfaceItem(item) == true)
    }
}
