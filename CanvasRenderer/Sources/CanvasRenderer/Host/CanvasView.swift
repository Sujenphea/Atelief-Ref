import SwiftUI

/// SwiftUI wrapper around ``CanvasHostView``. Drives the canvas from any
/// ``TileProvider`` + ``TileImageSource`` — the spike passes its dummy generator
/// and fixture set; build-order step 5's real view passes a `CollectionItem`-
/// backed provider/source. The host is rebuilt (not mutated) when the content
/// changes, so callers swap boards with SwiftUI's `.id(_:)`.
public struct CanvasView: NSViewRepresentable {
    private let provider: any TileProvider
    private let images: any TileImageSource

    public init(provider: any TileProvider, images: any TileImageSource) {
        self.provider = provider
        self.images = images
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(provider: provider, images: images)
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {}
}
