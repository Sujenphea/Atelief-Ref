// AtelierBrowse — which nothing a grid is showing (098 · P6).
//
// The whole input space is four small numbers, so this enumerates rather than samples:
// the resolver is exhaustive over the combinations that matter, and the wording is
// asserted as a shape (every case has both lines, they differ, they are sentences) rather
// than as four literals nobody would notice going stale.

import Foundation
import Testing

@testable import AtelierBrowse

@Suite("BrowseEmptyState: four kinds of nothing (093 § 7, 098 · P6)")
struct BrowseEmptyStateTests {

    // MARK: - There is something to draw

    @Test("a grid with items is not empty, whatever else is true")
    func itemsMeanNotEmpty() {
        for isUnsorted in [true, false] {
            for subcollections in [0, 3] {
                for collections in [1, 9] {
                    #expect(
                        BrowseEmptyState.resolve(
                            isUnsorted: isUnsorted, itemCount: 1,
                            subcollectionCount: subcollections,
                            libraryCollectionCount: collections) == nil)
                }
            }
        }
    }

    // MARK: - The four

    @Test("Unsorted, empty, and the only collection there is: the library is empty")
    func emptyLibrary() {
        #expect(
            BrowseEmptyState.resolve(
                isUnsorted: true, itemCount: 0, subcollectionCount: 0,
                libraryCollectionCount: 1) == .emptyLibrary)
        // A library with no tree at all — the state before the first read returns — reads
        // the same way rather than falling through to a different sentence.
        #expect(
            BrowseEmptyState.resolve(
                isUnsorted: true, itemCount: 0, subcollectionCount: 0,
                libraryCollectionCount: 0) == .emptyLibrary)
    }

    @Test("Unsorted, empty, beside other collections: everything is filed")
    func emptyUnsorted() {
        #expect(
            BrowseEmptyState.resolve(
                isUnsorted: true, itemCount: 0, subcollectionCount: 0,
                libraryCollectionCount: 2) == .emptyUnsorted)
    }

    @Test("any other empty collection is just empty, and says so about itself")
    func emptyCollection() {
        // The library's size is not consulted here: a pushed collection with nothing in it
        // says nothing about Unsorted, which is a different screen.
        for collections in [1, 2, 40] {
            #expect(
                BrowseEmptyState.resolve(
                    isUnsorted: false, itemCount: 0, subcollectionCount: 0,
                    libraryCollectionCount: collections) == .emptyCollection)
        }
    }

    @Test("subfolders and no direct items is its own case — the one nothing used to draw")
    func onlySubcollections() {
        // The old condition was `items.isEmpty && subcollections.isEmpty`, so this screen
        // fell through to the grid branch and drew a panel of nothing under a chip row.
        for isUnsorted in [true, false] {
            #expect(
                BrowseEmptyState.resolve(
                    isUnsorted: isUnsorted, itemCount: 0, subcollectionCount: 2,
                    libraryCollectionCount: 3) == .onlySubcollections)
        }
    }

    @Test("subfolders beat the library-size question — the chips are on screen")
    func subcollectionsBeatEmptyLibrary() {
        #expect(
            BrowseEmptyState.resolve(
                isUnsorted: true, itemCount: 0, subcollectionCount: 1,
                libraryCollectionCount: 1) == .onlySubcollections)
    }

    // MARK: - The wording

    @Test("every case has a heading and a second line, and they are different sentences")
    func everyCaseIsWorded() {
        for state in BrowseEmptyState.allCases {
            #expect(!state.title.isEmpty)
            #expect(!state.detail.isEmpty)
            #expect(state.title != state.detail)
            // A heading, not a sentence: no full stop. The detail is the sentence.
            #expect(!state.title.hasSuffix("."))
            #expect(state.detail.hasSuffix("."))
        }
    }

    @Test("no two cases say the same thing — a duplicate would be a case with no reason")
    func wordingIsDistinct() {
        let titles = Set(BrowseEmptyState.allCases.map(\.title))
        let details = Set(BrowseEmptyState.allCases.map(\.detail))
        #expect(titles.count == BrowseEmptyState.allCases.count)
        #expect(details.count == BrowseEmptyState.allCases.count)
    }

    @Test("no empty screen names a control the phone does not have")
    func noPhantomVerbs() {
        // v1 browse is read-only (091 · D1). An empty state offering to "add" or "import"
        // would be the only place in the app promising a verb, and it would be the place a
        // user is most likely to look for one.
        for state in BrowseEmptyState.allCases {
            let text = (state.title + " " + state.detail).lowercased()
            for verb in ["tap", "add", "import", "create", "move", "delete", "button"] {
                #expect(!text.contains(verb), "\(state.rawValue) offers \(verb)")
            }
        }
    }

    @Test("the resolver is pure: the same inputs give the same answer")
    func resolverIsPure() {
        let first = BrowseEmptyState.resolve(
            isUnsorted: true, itemCount: 0, subcollectionCount: 0, libraryCollectionCount: 4)
        let second = BrowseEmptyState.resolve(
            isUnsorted: true, itemCount: 0, subcollectionCount: 0, libraryCollectionCount: 4)
        #expect(first == second)
    }
}
