# 010 — Production-Worthiness: What Remains Beyond Features

> Answers "what else does this need to be a production-worthy app?" — everything
> between *works correctly on my machine* and *a product someone else can install,
> trust with their data, and keep using*. Companion to
> [020-production-readiness-overview](../020-production-readiness-overview.md): the
> G1–G18 pass closed the correctness/hardening tier (P0 bugs, Keychain, streaming
> caps, TOCTOU, XCUITest smoke, drift-canary process); this doc inventories what that
> review scoped out or left open, plus net-new dimensions verified 2026-07-13.

## Current state (verified)

- **Backup/undo: nothing.** Zero `UndoManager` in the codebase; no snapshot,
  integrity-check, or restore path (see [008](./008-backup.md)); the README's library
  reset is a literal `rm -rf`.
- **Distribution: ~0%** (unchanged from 020). No Developer ID / notarization /
  hardened runtime; deployment target macOS 26.5; `AppIcon.appiconset` contains only
  `Contents.json` (no icon); extension has no icons or build/zip script (G12); no
  update mechanism (no Sparkle, not App Store); extension↔app version handshake
  absent; extension ID unpinned (G17); no privacy policy / channel decision (G14).
- **Process: no CI** (`.github/workflows` absent — ~710 tests run only by hand), and
  the working tree is again heavily dirty (the whole 004/005 nav+spaces epic
  uncommitted — the G15 pattern recurring).
- **UX shell:** no onboarding/first-run flow (extension pairing is undiscoverable),
  no `Settings` scene (token, library location, future backup/sort options have no
  home), sparse menu bar (no standard Edit/View menus, no ⌘Z, no ⌘,).
- **Unmeasured:** canvas Instruments pass still an open manual gate; no run has ever
  exercised a 10k+-item library; no accessibility audit; logging in only 3 files; no
  diagnostics export; localization undecided.
- **Done well already** (don't re-litigate): bounded thumbnail cache
  (`SharedThumbnail.swift:23`, countLimit 512), sandbox + loopback token security
  model, test discipline, append-only migrations.

## Gap groups, recommendations, tradeoffs

### 1 — Data safety (top priority; matters even single-user)

| Gap | Recommendation |
|---|---|
| No backup/snapshot/restore | Execute [008](./008-backup.md) H1–H3 (VACUUM INTO snapshots, pre-migration + pre-destructive hooks, restore flow, TM hardening). Everything else in this doc is safer once this exists. |
| No undo | App-level `UndoManager` for the destructive verbs: delete, remove-from-collection, move (009), reorder, rename. Register inverses at the model layer, each paired with its `AppServices` call (the same pattern [005](./005-spaces.md) specs for element editing — build the seam once, share it). Tradeoff: undo across async writes needs serialization through the model; start with the five verbs above, not a universal system. |
| No corruption detection | `PRAGMA integrity_check` (008's `integrityCheck()`) at bootstrap; on failure → guided restore-from-snapshot instead of a hang or silent reset. |

### 2 — Distribution edge (only matters when someone else installs it)

- **Signing/notarization (G13):** Developer ID + hardened runtime + `notarytool`
  in a scripted release lane; revisit the 26.5 deployment target (each minor step
  down widens the base; the floor is wherever the APIs actually used land — audit,
  don't guess).
- **Updates:** **Sparkle 2** (recommended) over App Store for v1 — the loopback
  server + extension pairing make App Store review risky, and Sparkle keeps the
  direct-download channel self-served. App Store can come later; nothing in the
  sandbox model precludes it.
- **Extension↔app compatibility:** version the capture API — extension sends its
  version, `/health` returns min/max supported; mismatch → explicit "update the
  extension/app" UI instead of silent drift. Small, prevents the worst support case.
- **Icons + packaging:** app icon; extension icons + a `zip` build script (G12).
- **Policy (G14):** privacy policy page + channel decision (recommend: unlisted Web
  Store listing first — real autoupdate, low review surface); pin the extension ID
  in `CaptureAuth` once stable (G17).

### 3 — Engineering process (cheap, compounding)

- **CI now:** GitHub Actions macOS runner — 4× `swift test` + `node --test` +
  `xcodebuild build` (compile-proof for the SwiftUI layer) on every push. The G5
  flake is fixed; if it recurs, quarantine rather than un-gate. ~1 day.
- **Commit hygiene:** land the uncommitted nav/spaces epic in reviewable slices;
  adopt "feature lands committed or it doesn't exist" — the G15 pattern has now
  recurred twice.

### 4 — First-run & shell UX

- **Onboarding:** a first-launch sheet: install extension → pair token (the flow
  exists, it's just undiscoverable) → capture something → drop zone tour. Empty
  states already exist; the *path into* the app doesn't.
- **Settings scene (⌘,):** token regenerate/copy, library location + size, backup
  target + retention ([008](./008-backup.md)), future per-app toggles. SwiftUI
  `Settings` scene — S effort, unblocks several other docs' UI homes.
- **Menu bar:** standard Edit (undo/redo/cut/copy/paste/select-all wired to the grid
  and 009's selection), View (sort modes from [007](./007-search-sort.md)), Window
  restoration. Mac users reach for these reflexively; their absence reads as "not a
  real Mac app".

### 5 — Quality dimensions (polish tier, schedule deliberately)

- **Scale validation:** scripted seeding of a 10k–50k-item TempLibrary; measure grid
  scroll, FTS latency, gallery cover query, reaper sweep; run the long-deferred
  canvas Instruments pass. Fix what measurement finds, not what intuition guesses.
- **Accessibility:** VoiceOver labels on grid cells/cards/rail, full keyboard-only
  operation audit (009's hover-circle needs a keyboard equivalent — it has one via
  ⌘-click; verify VoiceOver exposes selection state), contrast pass.
- **Diagnostics:** adopt `os.Logger` consistently (3 files log today); an "Export
  Diagnostics" action (recent logs + DB stats + versions, never library content);
  crash reporting **opt-in only** if ever (local-first ethos — recommend just
  MetricKit + user-initiated export, no third-party reporter).
- **Localization:** decide English-only v1 explicitly (recommended) and keep strings
  in a String Catalog so the door stays open.

## Suggested sequencing

1. **Now (protects everything after):** 008 H1–H3 snapshots + integrity check;
   undo for the five destructive verbs; CI; commit the outstanding epic.
2. **Before first outside tester:** app icon, signing + notarization script,
   Sparkle, onboarding, Settings scene, menu bar basics.
3. **Before public listing:** extension icons/packaging/policy/ID pinning, version
   handshake, scale pass, accessibility pass, diagnostics export.

## Effort

| Group | Effort |
|---|---|
| Data safety (008 H1–H3 + undo + integrity) | **M–L** |
| Distribution (signing, Sparkle, icons, handshake, policy) | **M** spread over many small tasks |
| CI + hygiene | **S** |
| Onboarding + Settings + menus | **M** |
| Scale + a11y + diagnostics | **M**, measurement-driven |

## Risks & edge cases

- Sparkle + sandbox requires the XPC installer path — well-trodden but fiddly;
  budget a day of signing hell.
- Lowering the deployment target may surface API availability breaks — audit with
  `-target` builds before promising a floor.
- Undo interleaved with remote captures (server ingests mid-undo-stack) — inverses
  must be id-based, never index-based.
- Web Store review of the bulk sweep is the one genuinely unpredictable gate (G14);
  the unlisted channel de-risks the timeline but not the policy question.

## Settled decisions

- None yet — this doc is the inventory + recommendations; sequencing choices below
  are proposals.

## Open questions

1. Is outside distribution actually a goal, and on what horizon? (Groups 2 and much
   of 4/5 are moot for a personal tool; group 1 and CI are not.)
2. Sparkle vs App Store vs both — confirm Sparkle-first.
3. Deployment-target floor: stay 26.x or audit for lower?
4. Crash reporting: MetricKit + manual export only (recommended), or a third-party
   reporter?
5. Undo scope v1: the five destructive verbs only (recommended), or also ingest
   ("un-import")?
