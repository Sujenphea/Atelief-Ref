//
//  ContentView.swift
//  AtelierRefs
//
//  Created by Sujen Phea on 30/06/2026.
//

import SwiftUI

// Two tabs over ONE shared ``IngestionModel`` (owned here): the infinite Canvas
// and the Library (nested folder tree + browsing + import). Both show the SAME
// selected folder — pick a folder in the Library, switch to Canvas, see it.
struct ContentView: View {
    @StateObject private var model = IngestionModel()

    var body: some View {
        TabView {
            CanvasScreen(model: model)
                .tabItem { Label("Canvas", systemImage: "square.grid.2x2") }
            LibraryView(model: model)
                .tabItem { Label("Library", systemImage: "folder") }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    ContentView()
}
