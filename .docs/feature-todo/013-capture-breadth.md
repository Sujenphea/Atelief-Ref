# 013 — Capture Breadth: Safari Extension, Clipboard Watcher

> Widening the intake funnel beyond Chrome. Settled scope (user, 2026-07-13):
> **Safari extension** (single-capture) and **clipboard watcher** are in;
> screenshot hotkey and an iOS share-sheet companion were considered and **not
> selected** — recorded below so the map stays closed.

## Status (re-verified against the tree 2026-08-10)

| Phase | State | Where |
|---|---|---|
| K1 `extension/` restructure | **not started** | `extension/src/` is still flat — ~30 sibling files, no `shared/`, no `chrome/` |
| K2 Safari target + glue | **not started** | no Safari Web Extension target; `CaptureAuth` knows no `safari-web-extension://` origin form |
| K3 clipboard watcher | **shipped** | `ClipboardWatcher.swift`, `ClipboardWatch.swift`, `ClipboardWatchTests` (the pure decision core, as specced) |

K3 was the independent phase and it landed. The remainder is **A** — the Safari
line, K1 then K2 — and it carries two costs this doc already names: K1 is a pure
refactor with no user-visible payoff, and K2 pulls in App Store review even for a
notarized app's bundled extension.

Two things worth settling before K1 is scheduled:

- **The restructure only gets more expensive.** Every capture platform added
  first (e.g. [020](020-capture-rednote.md)'s `rednote-hook.js` +
  `bulk-rednote.js`) is another file to move — though at +2 files the marginal
  cost is genuinely small, so this is a weak argument for doing K1 *first*.
- **K2 weakens the origin check by design.** The Safari extension origin carries
  a per-install UUID, so `CaptureAuth` would match on **scheme only**, leaving
  the 256-bit token as the sole real barrier. That is defensible and mirrors the
  shipped G17 posture, but it is a security decision that should be taken
  explicitly rather than discovered in a diff.

## Current state at the time of writing (historical — see Status above)

- Capture is Chrome-only: MV3 extension (`extension/`, vanilla JS, ~270
  `node --test` tests) → loopback `AtelierServer` (`:47321`) with Origin
  allowlist + 256-bit token. `CaptureAuth` accepts `chrome-extension://` origins.
- The in-app paths (drop, paste, link) work browser-independently already — this
  doc is about *in-browser* capture reach and ambient capture.

## A — Safari extension (single-capture port)

**Scope line: single-post capture only** — right-click save, toolbar popup,
current-page capture. **Bulk sweeps stay Chrome-only**: the sweep engine leans on
MAIN-world `fetch`/XHR interception and SW lifetime behaviors that differ enough
in Safari that porting the durable engine is its own epic; do not promise it.

- **Mechanism**: a Safari Web Extension target inside the Xcode project wrapping
  the *same JS*. Safari supports MV3; the port is mostly packaging + API-surface
  discipline, not a rewrite.
- **Code sharing (DRY, the design driver)**: restructure `extension/` into
  `shared/` (capture DTO builders, harvesting, token client — already pure,
  tested) + `chrome/` and `safari/` glue (manifest, background wiring,
  browser-API shims via `webextension-polyfill` or a thin hand shim). The
  `node --test` suite keeps covering `shared/` unchanged — port without losing a
  test.
- **App-side change**: `CaptureAuth` origin allowlist gains the
  `safari-web-extension://<uuid>` origin form (UUID is per-install — match on
  scheme, keep the token as the real barrier, mirroring the G17 posture).
- **Distribution**: ships *inside the app* (Safari extensions are app-bundled) —
  actually simplifies [010]'s story for Safari users: one notarized artifact, no
  separate store listing.
- Rejected: iOS-style `SFSafariExtensionHandler` legacy API (deprecated path);
  a separate Safari-only rewrite (anti-DRY).

**Effort: L** (restructure M + Safari target/glue M + pairing UX S).

## B — Clipboard watcher (opt-in ambient capture)

Opt-in mode: images copied anywhere land in Unsorted automatically.

- **Mechanism**: `NSPasteboard.general.changeCount` polling (~1 s timer — macOS
  has no pasteboard notification API); on change, read image data, ingest via the
  existing paste path. 18A hash dedup makes double-fires harmless.
- **Privacy is the design driver** (explicit over clever):
  - Off by default; enabled from Settings ([010]) AND a visible **menu-bar
    indicator** while active (click = pause/disable). Never silent.
  - Respect `org.nspasteboard.ConcealedType` / `TransientType` markers (password
    managers) — skip without logging content.
  - Images only; never text/files (scope creep = surveillance feel).
- **Provenance** (never null): platform `clipboard`, source = frontmost app's
  bundle id + localized name at copy time (best-effort; falls back to
  "Clipboard").
- Rejected: Finder folder-watch auto-import (different feature, weaker demand —
  drag/drop covers it; revisit on request).

**Effort: S–M** (the watcher is small; Settings + menu-bar indicator is half the
work).

## Not selected (recorded as out-of-scope, 2026-07-13)

- **Screenshot hotkey** (global region-capture → library): evaluated, not chosen.
  Cheapest of the four if demand appears later (ScreenCaptureKit + hotkey).
- **iOS share-sheet companion**: an entire iOS app + a transport, compounded by
  multi-Mac sync being a non-goal ([081](../081-backup-plan.md) note). Revisit only if mobile capture
  becomes a real habit.

## Schema / migration impact

**None.** `clipboard` rides the existing platform/source model; Safari reuses the
whole capture DTO path.

## Phased implementation

1. **K1 (M)** — `extension/` restructure into `shared/` + `chrome/` (pure
   refactor, all tests green before any Safari code). **Outstanding.**
2. **K2 (M)** — Safari target + glue + `CaptureAuth` origin form + pairing UX.
   **Outstanding**, and gated on the scheme-only origin decision above.
3. ~~**K3 (S–M)** — clipboard watcher + menu-bar indicator + Settings toggle.~~
   **Shipped.**

K3 was independent of K1/K2, which is why it went first.

## Test strategy

- `shared/` suite unchanged and green post-restructure (the K1 gate); shim layer
  gets contract tests (same calls → same shared-module behavior) under
  `node --test`.
- `CaptureAuth`: safari-origin accept/reject matrix (extends the existing
  exhaustive negative suite).
- Watcher: pure decision core (changeCount delta, concealed-type skip, image-type
  gate, dedup tolerance) with an injectable pasteboard protocol; timer glue thin.
- Safari end-to-end: manual runbook (Safari automation is poor) — mirror the
  Chrome capture checklist in [019](../019-bulk-import-verification.md) style.

## Effort: **A: L · B: S–M**

## Risks & edge cases

- Safari SW/background page lifetime differs from Chrome — keep `safari/` glue
  stateless (the shared modules already are; the durable state lives app-side).
- Safari extension review rides App Store review even for notarized apps'
  bundled extensions — factor into [010]'s distribution timeline.
- Watcher + user copying *from* the app (⌘C in [011]) must not re-ingest its own
  copies — tag the pasteboard with a private marker type and skip it.
- Frontmost-app provenance races the copy (user switches apps fast) —
  best-effort, documented as such.

## Settled decisions

- Safari single-capture + clipboard watcher in scope; bulk stays Chrome-only;
  screenshot hotkey + iOS companion explicitly not selected (user, 2026-07-13).

## Open questions

1. Safari pairing UX: reuse the token copy/paste flow (recommended) or attempt
   native-app messaging (Safari supports it; more moving parts)?
2. Watcher default batch behavior: each copy = separate Unsorted item (recommended)
   vs coalesce rapid-fire copies?
