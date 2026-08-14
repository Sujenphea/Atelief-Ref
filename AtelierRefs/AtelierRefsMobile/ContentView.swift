// TEMPORARY PLACEHOLDER — 092 · S4b-i. Not the app's UI, and not a draft of it.
// This exists only so the App Group wiring is observable on a simulator: it resolves
// `LibraryLocation.defaultRoot()` once and shows the path or the typed error.
// 093's design replaces this whole file in S5. Deliberately unstyled, no `Theme`.

import AtelierCapture
import SwiftUI

struct ContentView: View {
    private let result = Result { try LibraryLocation.defaultRoot() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch result {
            case .success(let root):
                Text("Library root")
                Text(root.path)
            case .failure(let error):
                Text("Library root unavailable")
                Text(String(describing: error))
            }
            Text("App Group: \(identifier)")
        }
        .font(.footnote.monospaced())
        .padding()
    }

    private var identifier: String {
        (try? LibraryLocation.appGroupIdentifier()) ?? "<missing>"
    }
}

#Preview {
    ContentView()
}
