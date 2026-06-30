import SwiftUI

/// SwiftUI wrapper around ``CanvasHostView`` for the manual smoothness harness
/// (decision T11) and for build-order step 5's eventual real view. Takes the
/// concrete (`Sendable`) dummy provider + fixture set for the spike.
public struct CanvasView: NSViewRepresentable {
    private let provider: DummyTileProvider
    private let images: FixtureImageSet

    public init(provider: DummyTileProvider, images: FixtureImageSet) {
        self.provider = provider
        self.images = images
    }

    public func makeNSView(context: Context) -> CanvasHostView {
        CanvasHostView(provider: provider, images: images)
    }

    public func updateNSView(_ nsView: CanvasHostView, context: Context) {}
}
