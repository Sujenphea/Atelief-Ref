// AtelierCore — App Services tag-search tests (007 G1 · structured filter + vocabulary)
//
// The structured tag filter added to `searchAssets` (S1): AND vs OR set
// semantics over 0/1/2/3 tags, dup-join safety, unknown ids, user-vs-agent
// distinctness, composition with text/platform/collection scope, keyset paging
// WITH a tag filter, and the token vocabulary (prefix + limit + both sources).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: tag search + vocabulary (007 G1)")
struct ServicesTagSearchTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// Ingest one DISTINCT asset (unique hash + url so 18A dedup never collapses
    /// two calls) into `c` and return its id.
    @discardableResult
    private func seed(
        _ services: AppServices, into c: UUID,
        platform: Platform = .web, title: String? = nil
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let url = platform == .web ? "https://e/\(unique)" : "https://x/\(unique)"
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: platform, originalURL: url, title: title, capturedAt: Date())
        return try await services.ingest(draft, from: source, into: c).asset.id
    }

    /// The id of the tag named `name`/`source` (must exist).
    private func tagID(_ services: AppServices, _ name: String, _ source: TagSource = .user,
                       on asset: UUID) async throws -> UUID {
        let tag = try await services.applyTag(name, to: asset, source: source)
        return tag.id
    }

    // MARK: set semantics — AND (.all)

    @Test("no tags → the filter is inert (all assets)")
    func zeroTags() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await seed(services, into: c.id)
        _ = try await seed(services, into: c.id)
        #expect(try await services.searchAssets(tagIDs: [], tagMatch: .all).count == 2)
    }

    @Test(".all requires every listed tag; .any requires one")
    func andVsOr() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)   // brass + wood
        let b = try await seed(services, into: c.id)   // brass only
        _ = try await seed(services, into: c.id)       // untagged

        let brass = try await tagID(services, "brass", on: a)
        _ = try await services.applyTag("brass", to: b, source: .user)  // same tag row
        let wood = try await tagID(services, "wood", on: a)

        // .all(brass, wood) → only `a`.
        let all = try await services.searchAssets(tagIDs: [brass, wood], tagMatch: .all)
        #expect(all.map(\.asset.id) == [a])

        // .any(brass, wood) → `a` and `b` (both carry brass). Order is created_at
        // DESC → the later-ingested `b` comes first.
        let any = try await services.searchAssets(tagIDs: [brass, wood], tagMatch: .any)
        #expect(Set(any.map(\.asset.id)) == [a, b])
    }

    @Test("a single tag returns exactly its assets")
    func oneTag() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        _ = try await seed(services, into: c.id)
        let brass = try await tagID(services, "brass", on: a)
        #expect(try await services.searchAssets(tagIDs: [brass]).map(\.asset.id) == [a])
    }

    @Test("three-tag .all narrows to the asset carrying all three")
    func threeTagAll() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)   // x,y,z
        let b = try await seed(services, into: c.id)   // x,y

        let x = try await tagID(services, "x", on: a)
        let y = try await tagID(services, "y", on: a)
        let z = try await tagID(services, "z", on: a)
        _ = try await services.applyTag("x", to: b, source: .user)
        _ = try await services.applyTag("y", to: b, source: .user)

        #expect(try await services.searchAssets(tagIDs: [x, y, z], tagMatch: .all).map(\.asset.id) == [a])
        #expect(Set(try await services.searchAssets(tagIDs: [x, y], tagMatch: .all).map(\.asset.id)) == [a, b])
    }

    @Test("a duplicated tag id in the filter does not skew .all")
    func dupTagIDSafe() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        let brass = try await tagID(services, "brass", on: a)
        // Passing the same id twice must still match `a` (distinct-set N == 1).
        #expect(try await services.searchAssets(tagIDs: [brass, brass], tagMatch: .all).map(\.asset.id) == [a])
    }

    @Test("an unknown tag id yields no results")
    func unknownTagID() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await seed(services, into: c.id)
        #expect(try await services.searchAssets(tagIDs: [UUID()], tagMatch: .all).isEmpty)
        #expect(try await services.searchAssets(tagIDs: [UUID()], tagMatch: .any).isEmpty)
    }

    @Test("user and agent tags of the same name are distinct filters")
    func userVsAgentSource() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        let b = try await seed(services, into: c.id)
        let userBrass = try await tagID(services, "brass", .user, on: a)
        let agentBrass = try await tagID(services, "brass", .agent, on: b)
        #expect(userBrass != agentBrass)
        #expect(try await services.searchAssets(tagIDs: [userBrass]).map(\.asset.id) == [a])
        #expect(try await services.searchAssets(tagIDs: [agentBrass]).map(\.asset.id) == [b])
    }

    // MARK: composition

    @Test("tag filter composes with text, platform, and collection scope")
    func combinedConjuncts() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let other = try await services.createCollection(name: "Other")

        // Target: pinterest, title "sunset", tagged brass, in `refs`.
        let target = try await seed(services, into: refs.id, platform: .pinterest, title: "Sunset")
        let brass = try await tagID(services, "brass", on: target)

        // Decoys, each violating exactly one conjunct.
        let webSunset = try await seed(services, into: refs.id, platform: .web, title: "Sunset")
        _ = try await services.applyTag("brass", to: webSunset, source: .user)      // wrong platform
        let pinOak = try await seed(services, into: refs.id, platform: .pinterest, title: "Oak")
        _ = try await services.applyTag("brass", to: pinOak, source: .user)          // wrong text
        let otherPin = try await seed(services, into: other.id, platform: .pinterest, title: "Sunset")
        _ = try await services.applyTag("brass", to: otherPin, source: .user)        // wrong collection

        let hits = try await services.searchAssets(
            text: "sunset", platform: .pinterest,
            tagIDs: [brass], tagMatch: .all, collectionID: refs.id)
        #expect(hits.map(\.asset.id) == [target])
    }

    @Test("collection scope alone narrows to that folder's members")
    func collectionScopeOnly() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let other = try await services.createCollection(name: "Other")
        let inRefs = try await seed(services, into: refs.id)
        _ = try await seed(services, into: other.id)
        #expect(try await services.searchAssets(collectionID: refs.id).map(\.asset.id) == [inRefs])
    }

    @Test("keyset paging with a tag filter covers every match once, no drift")
    func keysetWithTagFilter() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // 9 tagged targets interleaved with untagged noise.
        var tagged: [UUID] = []
        var brass: UUID?
        for i in 0..<9 {
            let a = try await seed(services, into: c.id, title: "t\(i)")
            let t = try await services.applyTag("brass", to: a, source: .user)
            brass = t.id
            tagged.append(a)
            _ = try await seed(services, into: c.id)  // untagged noise
        }
        let filter = [brass!]

        let oracle = try await services.searchAssets(tagIDs: filter, limit: 500).map(\.asset.id)
        #expect(oracle.count == 9)

        var collected: [UUID] = []
        var cursor: AssetPageCursor? = nil
        while true {
            let page = try await services.searchAssets(tagIDs: filter, limit: 4, after: cursor)
            if page.isEmpty { break }
            collected.append(contentsOf: page.map(\.asset.id))
            let last = page[page.count - 1].asset
            cursor = AssetPageCursor(createdAt: last.createdAt, id: last.id)
            if page.count < 4 { break }
        }
        #expect(collected == oracle)
        #expect(Set(collected).count == collected.count)  // no overlap
        #expect(Set(collected) == Set(tagged))            // exactly the tagged set
    }

    // MARK: vocabulary

    @Test("tagVocabulary prefix-matches case-insensitively, includes both sources")
    func vocabularyPrefix() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        _ = try await services.applyTag("Brass", to: a, source: .user)
        _ = try await services.applyTag("brassica", to: a, source: .agent)
        _ = try await services.applyTag("Oak", to: a, source: .user)

        let hits = try await services.tagVocabulary(prefix: "bras")
        #expect(Set(hits.map(\.name)) == ["Brass", "brassica"])
        // Agent + user sources both present.
        #expect(Set(hits.map(\.source)) == [.user, .agent])
    }

    @Test("tagVocabulary blank prefix lists all, honoring the limit")
    func vocabularyBlankAndLimit() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        for name in ["aa", "bb", "cc", "dd"] {
            _ = try await services.applyTag(name, to: a, source: .user)
        }
        #expect(try await services.tagVocabulary(prefix: "   ").count == 4)   // blank → all
        #expect(try await services.tagVocabulary(prefix: "", limit: 2).count == 2)  // limit honored
    }

    @Test("tagVocabulary treats LIKE wildcards in the prefix as literals")
    func vocabularyEscapesWildcards() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        _ = try await services.applyTag("50% off", to: a, source: .user)
        _ = try await services.applyTag("plain", to: a, source: .user)
        // A bare "%" must NOT match everything — it is a literal here.
        #expect(try await services.tagVocabulary(prefix: "%").isEmpty)
        #expect(try await services.tagVocabulary(prefix: "50%").map(\.name) == ["50% off"])
    }

    @Test("allTags returns the full inventory ordered by name")
    func allTagsOrdered() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await seed(services, into: c.id)
        _ = try await services.applyTag("Zebra", to: a, source: .user)
        _ = try await services.applyTag("Apple", to: a, source: .user)
        #expect(try await services.allTags().map(\.name) == ["Apple", "Zebra"])
    }
}
