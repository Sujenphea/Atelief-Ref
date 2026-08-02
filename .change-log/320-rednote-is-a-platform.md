# 320 — rednote is a platform (020 · K2)

rednote (Xiaohongshu) stops being a hole in the map. It gains a `Platform` case,
a capture extractor, host permissions and a CDN allowlist entry — and the 145
assets a manual harvest put in the library on 2026-07-31 are re-tagged to match.
K1's walled-host stopgap already shipped separately; the board sweep (K3) and the
video ladder (K4) remain out of scope.

## Summary

- **`Platform.rednote`** — `source.platform` is TEXT with no `CHECK`, so the case
  is purely additive. It joins the originalURL-required group in `Validation`
  (a note always has a canonical URL) and displays as "rednote" — lowercase,
  which is how the product spells itself.
- **`extractors/rednote.js`** (new) — right-click "Save to Atelier" on a note.
  `match()` covers **both** domains, `rednote.com` and `xiaohongshu.com`, via
  `hostIs`, so subdomains pass and `rednote.com.evil.com` does not. The note URL
  comes from the right-clicked link when the capture starts from a board or feed,
  and `cleanURL` drops the `xsec_token` query — a short-lived credential has no
  business in stored provenance.
- **`media-hosts.js`** — one entry, `rednote: (h) => hostIs(h, "rednotecdn.com")`.
  The apex covers `sns-i*` / `sns-web-i*` (images) and `sns-v*` (video) at once.
  Deny-by-default is the point of this list, so it is not widened further.
- **`manifest.json`** — host permissions for the two page domains and the CDN.
- **Migration `v18`** — the historical re-tag. See below.

## The media rule, and why it's a rewrite rather than a fetch

The page renders a signed, resized webp:
`sns-web-i10.rednotecdn.com/<ts>/<sig>/<key>!nc_n_webp_mw_1` — typically a 270 px
thumbnail. Drop the timestamp and signature segments and the `!` transform
suffix, ask the plain image node for the bare key, and
`http://sns-i27.rednotecdn.com/<key>` comes back **public, unsigned, and at full
resolution** (2022×2696 and up on the verified sample). So the bare form is what
`mediaUrl` asks for and the signed webp is kept as `mediaUrlFallback` — the same
prefer-original/keep-fallback shape `pickPinImages` uses for Pinterest's
`/originals/`, for the same reason: the original is the better image and the
rendered one is the guaranteed-loadable insurance.

The rewrite is idempotent (an already-bare URL rewrites to itself) and passes
non-rednote URLs straight through, so it is safe to apply unconditionally.

## Why the 145 rows get a migration rather than a Settings button

Those assets were captured before the platform existed, so they were stored as
`web` with the origin recorded only as `rawMetadata.source = "rednote"`. Left
alone they would filter, display and dedup as generic web captures forever, and
the library would quietly contain two kinds of rednote asset. That is a one-time
historical fact about one release boundary — not a thing a user should have to
find, understand, and press. So it runs once, on open, like v9's tag
normalization and v16's Unsorted reconcile.

The scope is deliberately narrow: `web` rows only, marker only, valid JSON only.
The `json_valid` guard rides **inside a `CASE`**, not as a preceding `AND` — only
`CASE` guarantees `json_extract` is never evaluated on a malformed value, and a
single garbage `raw_metadata` throwing "malformed JSON" would abort the whole
migration for every user who has one.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/Enums.swift` — `case rednote`.
- `AtelierCore/Sources/AtelierCore/Services/Validation.swift` — joins the
  originalURL-required group.
- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` — `v18` +
  `retagV18RednoteSources`; a note on the reserved `v17`.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — the display name.
- `extension/src/extractors/rednote.js` — new; exports `rednote` and the
  testable `toRednoteOriginal`.
- `extension/src/extractors/registry.js` — registered ahead of the `web`
  catch-all.
- `extension/src/media-hosts.js`, `extension/manifest.json` — the CDN allowlist
  entry and host permissions.
- Tests: `AtelierCoreTests/MigrationTests.swift` (new `MigrationV18Tests`, 4),
  `AtelierCoreTests/EnumRawValueTests.swift`,
  `AtelierCoreTests/ServicesValidationTests.swift`,
  `AtelierServerTests/CaptureDecoderTests.swift`,
  `extension/test/extractors.test.js` (6 new),
  `extension/test/media-hosts.test.js` (1 new + the rejection sets).

## Test results

- `swift test --package-path AtelierCore` — 588 tests passed.
- `swift test --package-path AtelierIngestion` — passed.
- `swift test --package-path AtelierServer` — passed.
- `extension/` `npm test` — 404 pass, 0 fail (397 before).
- `extension/` `npm run drift-check` — no drift; exits 1 on the pre-existing
  stale Instagram fixture (18d old against a 14d window), unchanged by this work.
- `AtelierRefs` scheme (`xcodebuild test`, `platform=macOS`) — **1065 passed,
  1 skipped, 0 failed**. The first (cold-build) run flaked 20
  `ThumbnailPipelineTests` / `ThumbnailWindowPrefetcherTests` cases; both suites
  pass in isolation on the unmodified base and pass in the re-run here, so the
  flake is timing under load, not this change.

## Migration notes

**`v18` — data-only, idempotent, no schema change.**

```sql
UPDATE source SET platform = 'rednote'
WHERE platform = 'web'
  AND CASE WHEN json_valid(raw_metadata)
           THEN json_extract(raw_metadata, '$.source') = 'rednote' ELSE 0 END;
```

Runs once on first open of an existing library; a fresh library matches nothing.
Untouched: `web` rows without the marker, rows whose `raw_metadata` is not valid
JSON, rows already on `rednote`, and rows on any other platform even when they
carry the marker. Re-running is a no-op, since the flipped rows are no longer
`web`.

**`v17` is deliberately skipped.** It is reserved by the space-camera persistence
column landing on its own branch. Migration identifiers are permanent names, not
a dense sequence — a gap costs nothing, a collision corrupts. The gap is noted at
`registeredIdentifiers`, in the migrator body, and in the pinning test.
