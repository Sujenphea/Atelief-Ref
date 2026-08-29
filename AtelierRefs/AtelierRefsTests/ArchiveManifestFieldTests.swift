//
//  ArchiveManifestFieldTests.swift
//  AtelierRefsTests
//
//  023 · A4 — the manifest exhaustiveness guard, and link two of a chain:
//
//      asset TABLE  ⇄  `Asset` record       — `AssetColumnCoverageTests` (Core)
//      `Asset` record ⇄  manifest AssetEntry — HERE
//
//  So a column added without a thought fails a test twice: once for the model,
//  once for the backup. The point is the SECOND failure. A field can be added to
//  the schema and the record and work perfectly in the app while being silently
//  dropped from every export — and the symptom only appears when someone
//  restores a backup months later and finds the value gone.
//
//  `archived_at` is exactly that field. It works everywhere in-app without the
//  manifest carrying it; the only thing that would have caught its absence is a
//  test like this one, or a user losing their whole shelf on a restore.
//
//  The comparison is made against what the types actually ENCODE — not a
//  hand-kept list of names, which is the thing this test exists to make
//  unnecessary.
//

import AtelierArchive
import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Backup manifest carries every asset field (023 · A4)")
struct ArchiveManifestFieldTests {

    /// Asset fields the manifest deliberately does NOT carry, each with the
    /// reason it is excluded. An entry here is a DECISION; the test's value is
    /// that adding one is deliberate rather than accidental.
    static let excluded: [String: String] = [
        "id":
            "identity is carried, but as the entry's own `id` — not a field the diff below can match by name.",
        "source_id":
            "carried as `source_id` on the entry, pointing at the manifest's own sources table.",
        "view_count":
            "LOCAL usage, not content. A restore into a second library should not import how often the original was opened.",
        "last_viewed_at":
            "local usage, as view_count.",
        "search_text":
            "DERIVED — the denormalized FTS text is rebuilt from the payload on ingest (rule 2: derived data is excluded).",
        "dedup_key":
            "DERIVED from kind + payload, recomputed by the ingest funnel. Carrying it would let a stale key survive a rule change.",
    ]

    /// A sample with EVERY field populated. `JSONEncoder` omits nil optionals,
    /// so a sparse fixture would silently shrink both sets below — and the
    /// exhaustiveness test would then pass by comparing two incomplete lists,
    /// which is the exact failure mode a guard like this is written to avoid.
    /// `scanIsNotVacuous` is what keeps this honest.
    private func fullyPopulatedAsset() -> Asset {
        Asset(
            id: UUID(), kind: .image, blobHash: "abc", mimeType: "image/png",
            width: 1, height: 1, duration: 2.5, fileSize: 1,
            downloadState: .downloaded, createdAt: Date(),
            name: "n", note: "note", isFavorite: true, archivedAt: Date(),
            sourceId: UUID(), viewCount: 3, lastViewedAt: Date(),
            payload: "{}", dedupKey: "k", searchText: "s")
    }

    /// The `Asset` record's field names, from what it actually encodes.
    private func assetFields() throws -> Set<String> {
        let data = try JSONEncoder().encode(fullyPopulatedAsset())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    /// The manifest entry's field names, from what it actually encodes. Built
    /// from a real `Asset` so the encoder sees the same shape the writer emits.
    private func manifestFields() throws -> Set<String> {
        let entry = ArchiveManifest.AssetEntry(fullyPopulatedAsset(), tags: [])
        let data = try JSONEncoder().encode(entry)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test("every Asset field is in the manifest or in the named excluded list")
    func everyFieldIsCarriedOrExcluded() throws {
        let fields = try assetFields()
        let carried = try manifestFields()
        let unaccounted = fields
            .subtracting(carried)
            .subtracting(Self.excluded.keys)
            .sorted()

        #expect(
            unaccounted.isEmpty,
            """
            Asset field(s) neither in the backup manifest nor in the excluded \
            list: \(unaccounted.joined(separator: ", ")). Decide: carry it in \
            ArchiveManifest.AssetEntry (and replay it in ImportReplay), or add \
            it to ArchiveManifestFieldTests.excluded with the reason it is \
            derived or local.
            """)
    }

    /// The excluded list must describe reality. An entry naming a field that no
    /// longer exists is stale documentation that would also mask a rename — the
    /// old name stays "excluded" while the new one goes unnoticed.
    @Test("the excluded list names only real Asset fields")
    func exclusionsAreReal() throws {
        let fields = try assetFields()
        let stale = Set(Self.excluded.keys).subtracting(fields).sorted()
        #expect(
            stale.isEmpty,
            "excluded list names field(s) that no longer exist: \(stale.joined(separator: ", "))")
    }

    @Test("every exclusion states a reason")
    func exclusionsAreJustified() {
        for (field, reason) in Self.excluded {
            #expect(reason.count > 20, "\(field) needs a real reason, not a placeholder")
        }
    }

    /// The regression this whole file exists for, asserted directly rather than
    /// only via the set arithmetic above.
    @Test("archived_at is carried, not excluded")
    func archivedAtIsCarried() throws {
        #expect(try manifestFields().contains("archived_at"))
        #expect(Self.excluded["archived_at"] == nil)
    }

    /// A guard whose sets came back empty would pass while checking nothing.
    @Test("the field scan is not vacuous")
    func scanIsNotVacuous() throws {
        let fields = try assetFields()
        let carried = try manifestFields()
        #expect(fields.count >= 15)
        #expect(carried.count >= 15)
        #expect(fields.contains("is_favorite"))
        #expect(carried.contains("is_favorite"))
    }
}
