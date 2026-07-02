//
//  ContentView.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import CanvasRenderer
import SwiftUI

// Chunk 5: two tabs — the EXISTING Canvas spike harness (unchanged) and the new
// Import demo that proves the ingestion capture loop end-to-end.
struct ContentView: View {
    var body: some View {
        TabView {
            CanvasTab()
                .tabItem { Label("Canvas", systemImage: "square.grid.2x2") }
            ImportView()
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// Phase 1 spike harness: drives the CanvasRenderer with ~5,000 deterministic
// dummy tiles so the infinite canvas can be exercised by hand (scroll to pan,
// pinch to zoom) — the manual smoothness checklist (decision T11). Preserved as
// its own tab; real collection data lands later.
struct CanvasTab: View {
    private static let provider = DummyTileProvider(
        config: DummyTileGenerator.Config(count: 5_000)
    )
    private static let images = FixtureImageSet(count: 24)

    var body: some View {
        CanvasView(provider: Self.provider, images: Self.images)
    }
}

#Preview {
    ContentView()
}
