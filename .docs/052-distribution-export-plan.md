# 052 — Distribution + Export Plan

> Kind: `plan`. Covers the two gaps that separate AtelierRefs from "fully usable":
> **#1 Distribution** (a signed/notarized, auto-updating build anyone can install) and
> **#2 Export** (getting references *out* — copy, moodboard/PDF, contact-sheet/HTML).
>
> This plan was produced through a structured review across Architecture, Code Quality,
> Tests, and Performance. Every decision below was chosen explicitly. Decision tags
> (e.g. `2A`, `10A`) are referenced throughout the implementation phases.

## Locked decisions

### Architecture
- **1A — Channel:** Developer ID direct download + Sparkle auto-update. (Sparkle is
  incompatible with the Mac App Store; the loopback capture server + extension pairing
  is a MAS review risk. MAS remains a possible *later, separate* project.)
- **2A — Sandbox:** Keep `com.apple.security.app-sandbox`; integrate Sparkle via its
  sandboxed Installer/Downloader XPC services. Preserves the security posture for an app
  that listens on a socket, and keeps a future MAS door open.
- **3A — Export module boundary:** New `AtelierExport` SPM package holding pure
  layout+render logic; the app target keeps only `NSSavePanel`/pasteboard glue. Matches
  the existing package-per-domain architecture and gives host-free unit tests.
- **4A — Selection unification:** One `ExportSelectionProvider` protocol + one
  `AssetPasteboardWriter`, adopted by grid / canvas / detail, so the
  selection→`[AssetExportItem]` mapping exists once (DRY).

### Code quality
- **5A — Secrets:** Keychain-backed, nothing committed. `notarytool` keychain profile;
  Developer ID cert in login keychain; Sparkle EdDSA private key in Keychain. Non-secret
  team ID in `Release.xcconfig`; `SECRETS.md` documents *locations*, never values.
- **6A — Release lane form:** Explicit `scripts/release.sh` + `ExportOptions.plist` using
  stock `xcodebuild` / `notarytool` / `stapler` / `create-dmg` / Sparkle `generate_appcast`.
  No Fastlane/Ruby toolchain. Explicit over clever.
- **7A — Export errors:** Explicit `ExportError` enum + per-item skip-with-report. Export
  processes every valid item, collects skips (media-less, missing blob), and surfaces a
  partial-success summary via the existing `ToastCenter`. Hard failures (disk-full,
  save-panel denied) throw a typed error shown as an error toast.
- **8A — Pasteboard contract:** Kind-aware, layered. Image/video → file URL + image data
  (TIFF/PNG); `.color` → hex string (+ optional swatch image); `.link` → URL string.
  Centralized in `AssetPasteboardWriter`, one documented switch on `AssetContent`.

### Tests
- **9A — Release-lane guard:** `scripts/verify-release.sh`, run in CI on release tags —
  asserts on the built artifact: `codesign --verify --deep --strict`, `spctl -a -t exec`,
  `stapler validate`, `notarytool` log, hardened-runtime + sandbox present, Sparkle
  `sign_update` signature verifies.
- **10A — Rasterizer tests (3 layers):** (1) pure layout/pagination tests with exact
  deterministic values (no rendering); (2) structural output tests (PDF page count,
  embedded-image count, document dimensions via `CGPDFDocument`); (3) a thin layer of
  golden-image tests with a tolerance threshold, quarantinable if a CI GPU differs.
- **11A — Selection/pasteboard tests:** Fake `ExportSelectionProvider` feeds each kind
  combination; assert the resulting `[AssetExportItem]` (count, order, media-less
  filtered). `AssetPasteboardWriter` writes to a *named scratch* `NSPasteboard` (not
  `.general`); assert exact `NSPasteboardType`s per kind. Follow the existing
  `AssetFilePromiseTests` `.serialized` + temp-file factory pattern.
- **12A — Config guards:** Unit tests asserting the built app's Info.plist has
  `SUFeedURL`/`SUPublicEDKey`, entitlements still declare app-sandbox + network.server,
  the generated appcast validates + its EdDSA signature verifies, and
  `MACOSX_DEPLOYMENT_TARGET` ≤ the agreed floor. Plus a documented manual
  staging-appcast test procedure (the one genuinely un-unit-testable step).

### Performance
- **13A — Render memory:** Decode each source sized to its rendered pixel footprint at
  target DPI (via `ImageDecoding.thumbnailCGImage(from:maxPixelSize:)`), draw sequentially
  inside an `autoreleasepool`. Peak memory ≈ one item, not the whole board. A *separate*
  "export full-resolution originals" path streams file copies and bypasses downscaling.
- **14A — No N+1:** `ExportSelectionProvider` reads the surface's already-loaded `items`
  (grid `model.items` and `SpaceModel.items` already carry `asset` + `source`), so the
  common path issues zero new queries; a single `WHERE id IN (…)` batch covers rare misses.
- **15A — Threading:** Export runs off-main (background `Task`/`OperationQueue`, mirroring
  `AssetFilePromiseDelegate`), reports item-by-item progress, is user-cancellable, and hops
  to `@MainActor` to fire the `ToastCenter` summary.
- **16A — Caching:** Export decodes its own output-sized sources and discards them; it
  reuses only the stateless `ImageDecoding` downsampler, not the live
  `CanvasRenderer.ThumbnailCache` (avoids cross-package coupling + wrong-sized images). No
  new persistent export cache (export is infrequent and mostly cold).

## Grounding — reused primitives (do not rebuild)

- `AssetExport.exportItem(asset:source:blobURL:) -> AssetExportItem?`
  (`AtelierRefs/AtelierRefs/AssetExport.swift:90`) — the asset→export payload; already
  guards media-less / missing-blob → `nil`. Filenames + UTType solved here.
- `MasonryGridHost.gridExportPlan(assetIDs:details:blobURL:)`
  (`AtelierRefs/AtelierRefs/MasonryGridHost.swift:1461`) — selection→export items in grid
  order; the reference implementation for the provider.
- `IngestionModel.blobURL(forAsset:)` (`IngestionModel.swift:1308`) — asset→full-res URL
  (pure path math); `thumbnailURL(forAsset:)` / `previewImageURL(forAsset:)` for tiers.
- `MediaStore` (`AtelierIngestion/.../Media/MediaStore.swift`) — `blobURL`, `readBlob`,
  `thumbnailURL`, `readThumbnail`.
- `ImageDecoding.thumbnailCGImage(from:maxPixelSize:)` — shared downsampler (13A/16A).
- `AssetContent` (`AtelierCore/.../Domain/AssetContent.swift:17`) — switch target for the
  pasteboard/render kind logic: `.image` / `.video` / `.color(hex:)` / `.link` / `.tweet`.
- `SpaceItem` (`AtelierCore/.../Domain/SpaceItem.swift:79`) — geometry for the moodboard:
  axis-aligned `x/y/w/h` + `z` stacking (no rotation field).
- `ToastCenter` — partial-success + error reporting surface (7A).
- Command wiring pattern: per-command `View` reached via `@FocusedValue`/`@FocusedObject`
  in `AtelierRefsApp.swift` `.commands` (`AtelierRefsApp.swift:30-55`).
- Test patterns: `AssetExportTests.swift`, `AssetFilePromiseTests.swift`
  (`.serialized` + temp-file/factory helpers).

## Current state (baseline)

- Signing: Automatic "Apple Development", `DEVELOPMENT_TEAM = L25247V6JG`,
  hardened-runtime ON, sandbox ON (`project.pbxproj`).
- `MACOSX_DEPLOYMENT_TARGET = 26.5` (placeholder) at pbxproj lines 347, 405, 489, 510.
- Entitlements (`AtelierRefs/AtelierRefs/AtelierRefs.entitlements`): app-sandbox,
  files.user-selected.read-only, network.client, network.server.
- Info.plist: only `UTExportedTypeDeclarations`; no Sparkle keys; versions via
  `GENERATE_INFOPLIST_FILE`.
- CI (`.github/workflows/ci.yml`): builds/tests 4 SPM packages + extension + app tests;
  `CODE_SIGNING_ALLOWED=NO`; no archive/sign/notarize/cache. Runners `macos-15` (note:
  may lack Xcode 26 — a self-hosted macOS 26 runner may be needed for release jobs).
- No signing/notarization/release scripts exist anywhere.
- Sparkle not referenced anywhere (only in planning docs).
- No canvas rasterizer exists — moodboard render is built fresh.

---

## Track A — Distribution (#1)

### A0 — Deployment-target audit + guard test
- Audit macOS-version-gated API usage (SPM packages already target `.macOS(.v14)`); pick a
  real floor and lower `MACOSX_DEPLOYMENT_TARGET` at all four pbxproj lines (347/405/489/510).
- Build to confirm the chosen floor compiles/links.
- Add the **12A** guard test asserting the target does not regress above the floor.
- *Rationale for first:* cheapest, highest immediate value — lets real testers install.

### A1 — Developer ID signing config
- Switch app target to **Developer ID Application** signing.
- Verify entitlements still declare app-sandbox + network.server (**2A**).
- Add non-secret `Release.xcconfig` (team ID) + `ExportOptions.plist`.
- Write `SECRETS.md` documenting Keychain locations (**5A**).

### A2 — Release + verify scripts
- `scripts/release.sh`: `xcodebuild archive` → export (Developer ID) →
  `notarytool submit --wait` → `stapler staple` → `create-dmg` → Sparkle `generate_appcast`.
  `set -euo pipefail`, one step per function (**6A**).
- `scripts/verify-release.sh`: the **9A** artifact assertions.

### A3 — Sparkle 2 integration
- Add Sparkle SPM dependency; embed the **sandboxed** Installer/Downloader XPC services
  and their entitlements (**2A**).
- `SPUStandardUpdaterController`; "Check for Updates…" via `CommandGroup(after: .appInfo)`
  following the `UndoRedoCommands` `@FocusedObject` pattern.
- `SUFeedURL` + `SUPublicEDKey` in Info.plist.
- `generate_keys` → store EdDSA private key in Keychain (**5A**); wire `generate_appcast`
  into `release.sh`.

### A4 — CI + config-contract tests
- Run `verify-release.sh` on release tags (resolve the macOS-26 runner question here).
- Add **12A** config-contract tests (Sparkle plist keys, entitlements snapshot, appcast
  schema + EdDSA validity, deployment-target floor).

### A5 — Chrome extension distribution
- Package the MV3 extension (icons/zip) for the Chrome Web Store.
- Write a privacy policy.

---

## Track B — Export (#2)

> Tracks A and B are independent and can interleave. Within B, ship **B0 → B1** (Copy)
> before the heavier **B2** rasterizer for a fast user-visible win.

### B0 — `AtelierExport` package + selection seam
- New `AtelierExport` SPM package (**3A**), added to the CI test matrix.
- `ExportSelectionProvider` protocol (**4A**); reuse `AssetExport.exportItem` /
  `gridExportPlan`; `ExportError` enum (**7A**).

### B1 — `⌘C` Copy (unified pasteboard)
- `AssetPasteboardWriter` (**8A** kind-aware contract).
- Adopt `ExportSelectionProvider` in grid / canvas / detail; resolve selection from
  already-loaded details, zero N+1 (**14A**).
- Copy command via `CommandGroup(replacing: .pasteboard)`.
- Tests per **11A** (fakes + scratch pasteboard).

### B2 — Moodboard / PDF rasterizer core
- Pure layout/pagination logic + `CGContext`(PNG)/PDF render.
- Output-sized sequential decode in `autoreleasepool` reusing the shared downsampler
  (**13A/16A**); off-main with progress + cancel (**15A**).
- Tests per **10A** (layout / structural / golden).

### B3 — Export UI + error surface
- `NSSavePanel` (scoped-bookmark write under sandbox); progress/cancel UI;
  `ToastCenter` partial-success summary (**7A**).
- Export… in `SelectionActionBar` overflow + `CommandGroup(after: .saveItem)`.

### B4 — Contact sheet + HTML export
- Collection contact-sheet and HTML export built on the B2 layout engine.

---

## Open questions / deferred
- Exact deployment-target floor: decided during A0 after the API audit + build.
- Release runner: GitHub-hosted `macos-15` may lack Xcode 26; a self-hosted macOS 26
  runner may be required for signing/notarization jobs (resolved in A4).
- Appcast + DMG hosting location (static host / GitHub Releases) — decide before A3 ships
  a real `SUFeedURL`.
- MAS as a later, separate track (explicitly out of scope here per 1A).
