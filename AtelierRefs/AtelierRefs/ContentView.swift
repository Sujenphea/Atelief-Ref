//
//  ContentView.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import CanvasRenderer
import SwiftUI

// Phase 1 spike harness: drives the CanvasRenderer with ~5,000 deterministic
// dummy tiles so the infinite canvas can be exercised by hand (scroll to pan,
// pinch to zoom) — the manual smoothness checklist (decision T11). Replaced by
// real collection data at build-order step 5.
struct ContentView: View {
    private static let provider = DummyTileProvider(
        config: DummyTileGenerator.Config(count: 5_000)
    )
    private static let images = FixtureImageSet(count: 24)

    var body: some View {
        CanvasView(provider: Self.provider, images: Self.images)
            .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
