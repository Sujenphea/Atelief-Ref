# 020 — Production Readiness: Review & Assessment (overview)

> A whole-app review of **ref-atelier** — architecture, intended purpose, and how
> close it is to being production-ready. Reconciles the self-reported status
> ([009-mvp-status](./009-mvp-status-overview.md), frozen at changelog 049) and
> the capture-publish checklist ([014-publish-readiness](./014-publish-readiness-overview.md))
> against a fresh read of the real source + a full test run (2026-07-13).
> Companion: the fix roadmap in [021-production-readiness-plan](./021-production-readiness-plan.md).

## What the app is (recap)

A native macOS app (Swift/SwiftUI + AppKit, Xcode 26) for curating a **local-first,
provenance-preserving library of design references**. Capture images/video from the
web → stored content-addressed on-device → organized into nested collections →
browsed in a dense **grid** or a Figma-style **infinite canvas**, with every asset
keeping its original source URL/platform. Single-user, single-machine.

Six components:

| Component | Tech | Role |
|---|---|---|
| `AtelierRefs` (app) | SwiftUI + AppKit | UI, ingestion model, canvas host, 3-tab shell |
| `AtelierCore` | GRDB / SQLite | Domain model, migrations, one App-Services mutation path, FTS5, jobs ledger |
| `AtelierIngestion` | Foundation, ImageIO | Content-addressed MediaStore, hashing, thumbnails, ingest pipeline |
| `AtelierServer` | FlyingFox | Loopback HTTP endpoint (`/ingest`, `/ingest-video`, `/jobs`, `/health`) |
| `CanvasRenderer` | Core Animation | Infinite-canvas engine (tiles, culling, LOD, decode scheduler) |
| `extension/` | Chrome MV3 | Single-post capture + bulk-sweep, riding the authenticated browser session |

## Verification performed (2026-07-13)

| Suite | Result |
|---|---|
| Extension `node --test` | **267–270 pass / 0 fail** |
| AtelierCore `swift test` | **194 pass** |
| AtelierIngestion `swift test` | **85 pass** |
| AtelierServer `swift test` | **73 pass** |
| CanvasRenderer `swift test` | **86–87 pass** — 1 intermittent flake (G5) |

Plus direct source reads (`CaptureAuth`, entitlements, token handling,
`IngestionModel` wiring) and two deep architecture passes (Swift + extension) with
`file:line`-cited findings.

## Verdict

**The engineering is genuinely strong.** Clean pure-core / injectable-glue seams
throughout, careful concurrency (actors, `@MainActor`, `Sendable`, no semaphores),
disciplined **append-only** migrations, a well-designed **durable** bulk-sweep state
machine (contiguous-prefix checkpointing, typed per-item outcomes, halt-on-wall), a
real **drift canary** for platform-API rot, and a sound localhost security model
(Origin allowlist + 256-bit constant-time token, ACAO never `*`, body caps). No
`try!`, no `fatalError` (bar one unreachable `init(coder:)`), no TODO/FIXME, no debug
`print`. The full MVP loop (capture → store → organize → grid+canvas → open source)
is code-complete and heavily unit-covered (~440 Swift + 270 JS tests, all green).

**It is not ready to ship to other users yet**, for two distinct reasons:

1. **A handful of real correctness/robustness bugs in the core** (not edge polish).
2. **The entire distribution + runtime-validation edge is unbuilt.**

For the author's own single-machine use it is largely usable today — but two of the
bugs (silent first-run failure, orphan-blob disk leak) would still bite.

Framing: **~90% of a great MVP, ~0% of a shippable product.** The hard, risky part
(canvas renderer, durable bulk engine, data core) is done and done well; what remains
is unglamorous but real.

## Gap inventory

Grouped by severity. IDs (`G#`) are referenced by the fix roadmap
([021](./021-production-readiness-plan.md)).

### 🔴 P0 — real bugs / ship-blockers

| ID | Gap | Where |
|---|---|---|
| **G1** | **First-run failures are invisible.** The only error `.alert` lives in the Library tab; the default tab is **Canvas**, which binds no alert. A `bootstrap()` failure with Canvas frontmost shows nothing → app looks hung. Canvas/Sweeps action errors also don't surface until the user switches tabs. | `ContentView.swift:18`, `LibraryView.swift:36`, `IngestionModel.swift:211` |
| **G2** | **Orphan-blob disk leak.** Blob is written before thumbnails/DB; if a later step throws, the `catch` returns `.failed` with **no `removeBlob`**. The blob has no DB row → `MediaReaper` can never reclaim it → unbounded disk growth on every fail-after-write item. | `IngestPipeline.swift:117–180`, `MediaReaper.swift:31` |
| **G3** | **`reorderItem` crash trap.** `Dictionary(uniqueKeysWithValues:)` on asset ids traps if a folder ever holds the same asset twice; the no-dup invariant isn't enforced on load. | `IngestionModel.swift:506` |
| **G4** | **Batch outcome/index misalignment on cancellation.** `runBounded`'s `compactMap` shortens the result array, silently breaking the documented "one outcome per input, in order" contract for any caller zipping inputs↔outcomes (paste/drag batch is exposed). | `IngestCoordinator.swift:76`, `IngestInput.swift:52` |
| **G5** | **Flaky determinism test.** CanvasRenderer T12 "pixel-identical images" failed once under full parallel load, passed in isolation (CoreGraphics render nondeterminism). Breaks the "deterministic CI" claim. | `SpikeDataTests.swift:99` |

### 🟠 P1 — hardening / robustness

| ID | Gap | Where |
|---|---|---|
| **G6** | **Capture token in plaintext UserDefaults, not Keychain** — a long-lived shared secret authorizing local writes, in a cleartext plist readable by any process running as the user. | `IngestionModel.swift:118,285` |
| **G7** | **Main-thread synchronous thumbnail read still on the canvas pan/zoom path** — N sync JPEG file reads on the main thread on a mass cache-miss (zoom LOD shift) → jank. The long-flagged line was never moved off-main. Profile first, then mirror the Library-side `Task.detached` read. | `CanvasContent.swift:91` ← `CanvasEngine.sync():272` ← `pan/zoom` |
| **G8** | **`RemoteImageFetcher` buffers the whole body before enforcing its 32 MB cap** (`session.data(from:)`) — memory-exhaustion vector on the bulk fetch path. | `RemoteImageFetcher.swift:82` |
| **G9** | **Two TOCTOU read-then-write races** in `pauseStaleOpenJobs` / `reconcileOrphanedKnownItems` — a job touched in the gap gets wrongly paused / its items wrongly deleted. Narrow windows. | `AppServices.swift:766,797` |
| **G10** | **DB error detail discarded** — every non-constraint failure (disk-full, corruption) collapses to opaque `.persistenceFailure`; plus swallowed errors (`try? … ?? [:]`) render a failed sweep as fake-healthy 0/0. | `AtelierError.swift:65`, `IngestionModel.swift:370` |

### 🟡 P2 — validation + distribution edge (unbuilt)

| ID | Gap | Where |
|---|---|---|
| **G11** | **Zero automated GUI coverage.** SwiftUI is compile-verified only; the `AtelierRefsUITests` target is Xcode template stubs (`testExample` = just `app.launch()`). No view/tab/drop/drag/inspector/sweep is ever driven. The manual E2E runbook ([019](./019-bulk-import-verification.md)) is only partially ticked. | `AtelierRefsUITests.swift:26` |
| **G12** | **Extension not packageable.** `manifest.json` has **no `icons`** (hard Web Store blocker) and there is **no build/zip script** — submissions are hand-made. | `extension/manifest.json`, `extension/package.json` |
| **G13** | **App distribution not configured.** Deployment target **macOS 26.5** → near-zero installed base; no Developer ID / notarization / hardened-runtime path (Automatic signing only). | `project.pbxproj` |
| **G14** | **ToS / "downloader" policy risk.** Bulk sweep + video-resolution paths are exactly what Web Store review and X/Pinterest ToS target; the human-pacing jitter can read as evasion. Needs a distribution-channel decision (unlisted vs public vs unpacked-only) + a **privacy policy**. | `config.js`, `twitter-video.js`, `bulk-pinterest.js` |

### ⚪ P3 — process / docs

| ID | Gap | Where |
|---|---|---|
| **G15** | **Working tree is 41 files dirty**, including 6 never-committed source files — the whole popup + Twitter-scope-filter feature is uncommitted. | `git status` |
| **G16** | **Stale status doc** — [009](./009-mvp-status-overview.md) frozen at changelog 049; ~28 changelogs since (bulk import, popup, layout). | `.docs/009` |
| **G17** | **Extension-id pinning deferred** — app accepts any `chrome-extension://` origin (token is the real barrier). Pin once the published id is stable. | `IngestionModel.swift:255`, `CaptureAuth.swift:57` |
| **G18** | **Platform-rot brittleness** (well-hedged): hardcoded Pinterest `pws-handler`, X op-name regex, syndication-token formula; drift canary exists but is manual/CI-excluded — operationalize a reminder. | `bulk-pinterest.js:236`, `twitter-hook.js:41`, `twitter-video.js:27` |

## What's genuinely done well (don't re-litigate)

- **Data core** — one mutation path, WAL + drift-free recomputed `ingested_count`,
  append-only migrations with never-edit shipped bodies, a real `JobLedger` seam.
- **Server security** — the Origin/token gate is pure, exhaustively negative-tested,
  and correctly reasoned (loopback is not isolation).
- **Bulk engine** — durable content-script loop, contiguous-prefix checkpointing,
  typed outcomes, halt-on-wall, SSRF CDN allowlist, stable per-target resume key.
- **Test discipline** — pure-core/injectable-glue everywhere; ~710 tests total.

## Non-goals of this review

Not a security audit, not a legal opinion (see [015 §legal posture](./015-bulk-import-overview.md)),
and not a performance profile (the canvas Instruments pass remains an open manual gate).
