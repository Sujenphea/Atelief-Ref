// AtelierCore — the asset-read surface, pinned by a source scan (023 · A)
//
// `ServicesShelfReadTests` asserts that each read APPLIES the archive predicate
// correctly. This file asserts something a behavioural test structurally cannot:
// that no read has been ADDED without anyone deciding. A new `FROM asset` query
// written next year has no test to fail — it simply returns archived rows into
// a surface that should not show them, and nothing says so.
//
// So the set of functions in `AppServices` that read the `asset` table is
// pinned, each with a stated reason. Adding a read fails this test until its
// name and its answer to "does this show archived items?" are written down.
//
// The precedent is the extension's `src/drift.js` CHECKS: a shape-level canary,
// deliberately coarse, whose whole value is that it fires on a change nobody
// thought to test.
//
// This MUST live in the SwiftPM test target. The app's test host is the
// sandboxed app and cannot read files in the repo — `ConfigContractTests.swift`
// documents the EPERM.

import Foundation
import Testing
@testable import AtelierCore

@Suite("AppServices: the asset-read surface is pinned (023 · A)")
struct AssetReadSurfaceTests {

    /// Every function in `AppServices` that reads the `asset` table, and what it
    /// does about the archive shelf. A reason is required — the point of the
    /// pin is the decision, not the name.
    ///
    /// If this test fails because you added a read: decide which line you are
    /// on, apply the predicate if you are browsing, and add the entry.
    static let allowed: [String: String] = [
        // ── Browsing. These HIDE archived items. ─────────────────────────────
        "collectionItems":
            "the grid. Hides archived unless the caller passes includeArchived: true (the backup writer, which copies the library rather than viewing it).",
        "collectionItem":
            "one membership of one collection, for a detail screen opened from a tile (098 \u{00B7} 13). The same join as collectionItems with a primary-key predicate, so it takes the same non-defaulted includeArchived and answers it the same way — a row hidden from the grid must not be reachable by deep-linking its id.",
        "searchAssets":
            "keyword search. Hides archived via a WHERE conjunct, never a post-filter — a post-filter shortens pages.",
        "semanticSearchAssets":
            "meaning search. Hides archived at the candidate stage, so flipping keyword → meaning cannot resurrect a shelved item.",
        "covers":
            "the shared cover lookup behind collectionCovers / spaceCovers. An archived cover falls out and the card falls back to a visible member.",
        "stackPreviews":
            "the shared count + fan behind collectionStackPreviews / spaceStackPreviews. Both queries hide archived, and they must agree.",

        // ── The shelf itself. These show ONLY archived items. ────────────────
        "shelfAssets":
            "the Archived destination — the whole library filtered to archived_at IS NOT NULL, newest first.",
        "archivedUsage":
            "the Library pane's shelf row (016 / 023 · A4). Counts ONLY archived rows, and reports the bytes only archived assets hold — the one read whose subject IS the shelf.",
        "archivedAssetIDs":
            "the archived subset of an explicit id set, for mixed-selection verb availability.",

        // ── Deliberately INCLUDES archived items. ────────────────────────────
        "getAsset":
            "one asset by id. An archived item's detail page has to open — that is how you unarchive it.",
        "favoritedAssetIDs":
            "the favorited subset of an explicit id set. Archived items stay favoritable; archive hides an item, it does not freeze it.",
        "referencedBlobHashes":
            "the orphan sweep's KEEP SET. Must include archived, or the shelf becomes a shelf of missing files.",
        "assetIDsNeedingColorBuckets":
            "the color-derivation backfill queue (085 · C1). Joins asset only to order newest-first. Deliberately includes archived: an item on the shelf still needs its buckets derived, or unarchiving it would leave a hole in the color filter that nothing ever fills.",
        "referencedBlobs":
            "the off-device copy set. Same reason as referencedBlobHashes — an archived item's bytes are still the user's.",
        "blobUsage":
            "the reclaim-space accounting. Must include archived: 'what can I free' is precisely the question the shelf creates.",
        "assetCountsByKind":
            "library stats (016). Counts everything; the archived slice is reported separately rather than silently omitted.",
        "assetCountsByPlatform":
            "library stats (016). Same as assetCountsByKind.",
        "assetsNeedingAnalysis":
            "the analysis queue. Archived items are still analyzed — unarchiving must not reveal an item with no OCR, colors or hash.",
        "assetsNeedingSuggestions":
            "the suggested-tag queue (012 · I3). Same line as assetsNeedingAnalysis: archived items are still classified, so unarchiving one does not show a bare item whose chips arrive an idle pass later. The queue is bounded per pass, so the shelf cannot starve the visible library.",
        "assetsNeedingEmbedding":
            "the embedding queue. Same as assetsNeedingAnalysis.",
        "embeddingsToReverify":
            "the embedding re-verify window. Same as assetsNeedingEmbedding.",
        "perceptualHashes":
            "duplicate detection. A duplicate of an archived item is still a duplicate.",
        "reconcileOrphanedKnownItems":
            "an existence check against the bulk-import ledger, not a browsing read.",

        // ── Write paths that read to write. Not browsing. ────────────────────
        "captureBackup":
            "the delete-undo snapshot. Captures whole Asset rows, so archived_at rides along and ⌘Z restores an item ARCHIVED.",
        "performDelete":
            "the delete itself. Deleting an archived item is an ordinary recoverable delete.",
        "restoreDeletedAssets":
            "the delete-undo restore, the inverse of captureBackup.",
        "setName":
            "a single-asset editor. Archived items stay editable.",
        "setNote":
            "a single-asset editor. Same as setName.",
    ]

    /// What counts as reading the `asset` table: raw SQL naming it, and the
    /// record types that read it through GRDB's query interface (which carries
    /// no SQL text to grep for). `asset_fts` / `asset_tag` / `asset_analysis` /
    /// `asset_embedding` are deliberately NOT matched — `\b` does not break on
    /// `_`, so those are different tables, correctly.
    /// Computed, not a stored static: `Regex` is not `Sendable`, and a shared
    /// mutable global is exactly what Swift 6 is right to refuse.
    private var readPatterns: [Regex<AnyRegexOutput>] {
        [
            #/\b(?:FROM|JOIN)\s+asset\b/#,
            #/\bAsset(?:SourceRow)?\.fetch(?:All|One)\b/#,
            #/\bCollectionItemRow\.fetch(?:All|One)\b/#,
            #/\bAsset\.filter\b/#,
            // The P0 `require` helper is a fetch-by-key with the record type as
            // an argument, so the plain `Asset.fetchOne` spelling above no longer
            // appears at those sites. Without this arm `setName` / `setNote`
            // silently left the pinned surface — which is exactly the class of
            // disappearance this whole file exists to catch, arriving through a
            // refactor rather than a deletion.
            //
            // No leading `\b`: `Self.require` is ONE word to Swift Regex, because
            // UAX #29 does not break on a `.` between two letters (it is how "e.g."
            // stays a word). A `\brequire` here silently matches nothing.
            #/require\(Asset\.self\b/#,
        ].map { Regex<AnyRegexOutput>($0) }
    }

    /// Every file the `AppServices` surface is spelled across, DISCOVERED rather
    /// than listed: `AppServices.swift` plus each `AppServices+*.swift`.
    ///
    /// The surface used to be one 4,200-line file and this scan read exactly it.
    /// The P0 split moved the sections into per-subject extensions, and a canary
    /// that names one file would have kept passing while scanning a tenth of the
    /// surface — the precise way a shape-level check dies unnoticed. A directory
    /// listing means the next extension file added is scanned the day it lands,
    /// with no edit here.
    private func appServicesSources() throws -> [(name: String, text: String)] {
        // …/AtelierCore/Tests/AtelierCoreTests/<this file>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // AtelierCoreTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // AtelierCore
        let services = packageRoot.appendingPathComponent("Sources/AtelierCore/Services")
        let names = try FileManager.default
            .contentsOfDirectory(atPath: services.path)
            .filter { $0.hasPrefix("AppServices") && $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: services.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// The read sites across the whole surface, merged. Scanned per FILE rather
    /// than over a concatenation, so the "which function am I in" cursor cannot
    /// run off the end of one file into the next.
    private func allReadSites() throws -> [String: [Int]] {
        var merged: [String: [Int]] = [:]
        for file in try appServicesSources() {
            for (name, lines) in readSites(in: file.text) {
                merged[name, default: []].append(contentsOf: lines)
            }
        }
        return merged
    }

    /// Function name ⇒ the 1-based lines in it that read `asset`.
    private func readSites(in source: String) -> [String: [Int]] {
        var sites: [String: [Int]] = [:]
        var current = "<file scope>"
        let patterns = readPatterns          // built once, not per line
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let text = String(line)
            if let match = text.firstMatch(
                of: #/^ {4}(?:public |private |internal )?(?:static )?func (\w+)/#) {
                current = String(match.1)
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // Comments describe reads; they are not reads. Without this the doc
            // comment ABOVE a function would be attributed to the one before it.
            guard !trimmed.hasPrefix("//") else { continue }
            if patterns.contains(where: { trimmed.firstMatch(of: $0) != nil }) {
                sites[current, default: []].append(index + 1)
            }
        }
        return sites
    }

    @Test("every function reading the asset table is pinned with a stated reason")
    func readSurfaceIsPinned() throws {
        let sites = try allReadSites()
        let found = Set(sites.keys)
        let pinned = Set(Self.allowed.keys)

        let added = found.subtracting(pinned).sorted()
        let removed = pinned.subtracting(found).sorted()

        #expect(
            added.isEmpty,
            """
            New asset read(s) in AppServices with no decision recorded: \
            \(added.map { "\($0) (line \(sites[$0]?.first.map(String.init) ?? "?"))" }
                .joined(separator: ", ")).
            Decide whether each one shows archived items — browsing reads must \
            not — then add it to AssetReadSurfaceTests.allowed with the reason.
            """)
        #expect(
            removed.isEmpty,
            """
            Pinned asset read(s) no longer present: \(removed.joined(separator: ", ")). \
            If they were removed or renamed, update AssetReadSurfaceTests.allowed.
            """)
    }

    /// A scan that silently matched nothing would pass the test above while
    /// guarding nothing at all — the classic way a canary dies unnoticed.
    @Test("the scan actually reads the file and finds the surface it claims to")
    func scanIsNotVacuous() throws {
        let files = try appServicesSources()
        // The surface is split; a scan that found one file found a tenth of it.
        #expect(files.count > 1, "expected AppServices.swift + its extensions")
        #expect(files.contains { $0.name == "AppServices.swift" })
        let joined = files.map(\.text).joined(separator: "\n")
        #expect(joined.contains("public func searchAssets"))
        let sites = try allReadSites()
        #expect(sites.count >= 20)
        // Spot-check both matcher families: raw SQL and the query interface.
        #expect(sites["referencedBlobHashes"]?.isEmpty == false)   // FROM asset
        #expect(sites["collectionItems"]?.isEmpty == false)        // CollectionItemRow
        // …and that a different table is NOT mistaken for this one.
        #expect(sites["tags"] == nil)                              // FROM asset_tag only
    }

    @Test("every pinned read states a reason")
    func reasonsAreStated() {
        for (name, reason) in Self.allowed {
            #expect(reason.count > 20, "\(name) needs a real reason, not a placeholder")
        }
    }
}
