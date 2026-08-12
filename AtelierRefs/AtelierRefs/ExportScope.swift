//
//  ExportScope.swift
//  AtelierRefs
//
//  The two decisions every export makes before it makes its own: WHICH rows it
//  covers, and what to call the thing it writes.
//
//  Both used to be per-export. `ContactSheetExport.rows` (052 · B3) was the
//  original; `CollectionSiteExport.rows` (014 · S3) was a copy of it; the originals
//  export (011 · A2) then added a third name that delegated to the first — three
//  public spellings of one filter, one of them a genuine fork, held together by a
//  test that asserted the three agreed. A test whose only job is to check that
//  duplicated code has not drifted is a sign the duplication should go instead.
//
//  So this is that filter, once. It is deliberately tiny: the point is not that the
//  logic is complex, it is that "what does an export act on?" has exactly one
//  answer in this app, and a fourth export cannot quietly invent a different one.
//

import AtelierCore
import Foundation

enum ExportScope {

    /// The rows an export considers: the SELECTION when anything is selected, else
    /// the whole collection.
    ///
    /// Selection wins because it is the more specific statement of intent — someone
    /// who selected twelve refs and hit Export meant those twelve. An empty
    /// selection is not a statement at all, so it falls back to everything on
    /// screen, which is what makes `File ▸ Export…` work with nothing selected.
    ///
    /// Matches by MEMBERSHIP id (`item.id`), because that is what a grid selection
    /// holds. The right-click path matches by asset id instead — see
    /// ``ExportScope/rows(items:assetIDs:)``.
    static func rows(
        items: [CollectionItemDetail], selectedIDs: Set<UUID>
    ) -> [CollectionItemDetail] {
        selectedIDs.isEmpty ? items : items.filter { selectedIDs.contains($0.item.id) }
    }

    /// The rows for an explicit set of ASSET ids — the right-click path, whose
    /// Finder-scope targets (`gridActionTargets`) are asset ids rather than
    /// memberships.
    ///
    /// Returns them in `items` order, NOT in `assetIDs` order: the feed the user is
    /// looking at is the order an export should write and a share should hand over,
    /// and the caller's id collection has no meaningful order of its own. An empty
    /// `assetIDs` yields nothing rather than everything — unlike ``rows(items:selectedIDs:)``,
    /// because an explicit empty target list IS a statement: there is nothing to act on.
    static func rows(
        items: [CollectionItemDetail], assetIDs: [UUID]
    ) -> [CollectionItemDetail] {
        let wanted = Set(assetIDs)
        return items.filter { wanted.contains($0.asset.id) }
    }

    /// The folder name a save panel suggests for `collectionName`, run through the
    /// shared sanitizer so a collection called `Refs / Q3` cannot propose a path
    /// separator.
    ///
    /// A name that is nothing but whitespace short-circuits to `"Refs"`:
    /// `AssetExport.sanitize` falls back to `"image"`, which is the right word for
    /// one file and the wrong one for a folder of many.
    static func folderName(for collectionName: String) -> String {
        let trimmed = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Refs" : AssetExport.sanitize(trimmed)
    }
}
