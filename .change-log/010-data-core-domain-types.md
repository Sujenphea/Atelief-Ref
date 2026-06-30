# 010 — Data core: domain value types + enums

**Chunk 2** of the data-core build: the pure domain value types and enums that
the rest of `AtelierCore` sits on (003 §data-model). Plain data carriers only —
no GRDB, no persistence, no validation. Database conformances (A1) and the
validation funnel (C8) land in later chunks as extensions.

## Summary

Added the `Domain/` layer to `AtelierCore`: four `String`-backed enums, the
recursive `JSONValue` carrier for `Source.rawMetadata`, and the five core
structs plus the reserved `AssetTag` join row. Each type is `public`, `Sendable`,
`Equatable`, `Hashable`, `Codable`, and `Identifiable` where it has an `id`.
Fields mirror the 003 §data-model tables exactly, in Swift camelCase (DB column
mapping is deferred). No file under `Domain/` imports GRDB — the compiler keeps
the domain types plain.

## Decisions realized

- **C5 — readable text encodings.** All enums are `String` rawValue, with
  explicit snake_case on the multi-word `Platform` cases (`local_paste`,
  `local_drag`) so the on-disk encoding is stable and agent-readable and
  survives case reordering. Tests assert each rawValue exactly.
- **Explicit over clever.** `Source.rawMetadata` is the recursive
  `JSONValue` enum (`.null/.bool/.number/.string/.array/.object`), not
  `Any`/AnyCodable. Its `Codable` uses a single-value container and, on decode,
  probes `decodeNil()` first, then `Bool`, `Double`, `String`, `[JSONValue]`,
  `[String: JSONValue]` — so `null` never collapses into `false` and arbitrary
  nested JSON round-trips losslessly. Encode mirrors each case back through the
  single-value container.
- **C6 — provenance required.** `Asset.sourceId` is a non-optional `UUID`; the
  memberwise init has no default for it, so an asset-with-no-origin cannot be
  constructed.
- **Dumb structs.** Memberwise inits give sensible defaults only where 003 marks
  a field optional (`Asset.duration = nil`; all `Source` optionals `nil`,
  `rawMetadata = .object([:])`; `Collection.description`/`coverAssetID = nil`;
  all `CollectionItem` placement fields `nil`). No computed invariants.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/Enums.swift` *(new)* — `AssetKind`,
  `Platform`, `DownloadState`, `TagSource` (`String`, `Sendable`, `Codable`,
  `CaseIterable`, `Hashable`).
- `AtelierCore/Sources/AtelierCore/Domain/JSONValue.swift` *(new)* — recursive
  `JSONValue` enum + hand-written lossless `Codable`.
- `AtelierCore/Sources/AtelierCore/Domain/Asset.swift` *(new)*.
- `AtelierCore/Sources/AtelierCore/Domain/Source.swift` *(new)*.
- `AtelierCore/Sources/AtelierCore/Domain/Collection.swift` *(new)*.
- `AtelierCore/Sources/AtelierCore/Domain/CollectionItem.swift` *(new)*.
- `AtelierCore/Sources/AtelierCore/Domain/Tag.swift` *(new)* — `Tag` +
  reserved `AssetTag` join (no `id`).
- `AtelierCore/Tests/AtelierCoreTests/EnumRawValueTests.swift` *(new)* — exact
  rawValue assertions, case-count pins, round-trips (`@Test(arguments:)`).
- `AtelierCore/Tests/AtelierCoreTests/JSONValueTests.swift` *(new)* — scalar,
  nested, raw-literal, top-level array, empties, null≠false round-trips.
- `AtelierCore/Tests/AtelierCoreTests/DomainModelTests.swift` *(new)* — Codable
  round-trips for every struct (incl. populated `rawMetadata`) + default-init
  + identity/hashable checks.

## Verification

- `cd AtelierCore && swift test` — **28 tests in 4 suites passed** (the 3 new
  Domain suites plus the chunk-1 package smoke suite).
- `grep -rl "import GRDB" AtelierCore/Sources/AtelierCore/Domain/` —
  **OK: no GRDB in Domain**.

## Migration notes

None — additive. The domain types are `public` but nothing constructs them yet.
GRDB record conformances are added as `Persistence/*+GRDB.swift` extensions in
chunk 4; the camelCase property names map to snake_case DB columns there.
