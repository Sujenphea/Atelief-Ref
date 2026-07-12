# 021 — Production Readiness: Implementation Plan (plan)

> The ordered fix roadmap for the gaps catalogued in
> [020-production-readiness-overview](./020-production-readiness-overview.md).
> Gap IDs (`G#`) reference that doc. Each phase is independently shippable and
> ends with a concrete verification. Do the phases in order — P0 first (real bugs
> that bite even single-user), then hardening, then the distribution edge.

## Context

The review ([020](./020-production-readiness-overview.md)) found the core
engineering strong but surfaced five real correctness bugs and an entirely unbuilt
distribution/validation edge. This plan sequences the work to close them. The
intended outcome: an app that is (a) correct and safe for the author's daily use,
then (b) packageable and validated enough to hand to another user.

Guiding rules (from the repo's standing practice):
- **Verify the real root cause on real data before fixing** — no symptom patches.
- One changelog entry per completed chunk (`.change-log/NNN-*.md`).
- Keep the pure-core / injectable-glue seam; add tests at the pure layer.

---

## Phase 1 — P0 correctness bugs (do first)

Small, high-value, mostly local. Each is a genuine defect, not polish.

### 1.1 — Hoist the error alert to the app shell (G1)
**Problem:** the only `.alert(model.lastError)` is on `LibraryView` (`:36`), but the
default tab is Canvas (`ContentView.swift:18`), so a `bootstrap()` failure
(`IngestionModel.swift:211`) shows nothing.
**Fix:** move the `.alert` (bound to `model.lastError`) up to `ContentView`'s
`TabView` (or the `WindowGroup` root in `AtelierRefsApp.swift`) so it fires
regardless of the selected tab. Remove the now-redundant Library-local alert.
**Verify:** force `bootstrap()` to throw (e.g. point the library dir at an
unwritable path) with Canvas frontmost → alert appears. Add a note to the doc-019
manual runbook.

### 1.2 — Plug the orphan-blob leak (G2)
**Problem:** `IngestPipeline.ingest` writes the blob at `:117` before thumbnails/DB;
the `catch` at `:180` returns `.failed` without `removeBlob`, leaving an
unreferenced blob the reaper can't reclaim.
**Fix:** in the failure path after a successful blob write (and before a DB row
exists), best-effort `store.removeBlob(hash)` — but only when this call *created*
the blob (respect the hash-first dedup short-circuit at `:116`; never delete a blob
a prior asset legitimately shares). Guard on "did we just write it this call".
**Verify:** unit test — inject a thumbnail/DB failure, assert the blob file is gone
and no DB row exists; add a dedup case proving a shared blob is *not* deleted.

### 1.3 — Fix the `reorderItem` crash trap (G3)
**Problem:** `Dictionary(uniqueKeysWithValues: items.map { ($0.asset.id, $0) })`
(`IngestionModel.swift:506`) traps on duplicate asset ids.
**Fix:** either use `Dictionary(items.map …, uniquingKeysWith: { a, _ in a })`, or
enforce/assert de-dup in `loadContents`. Prefer the defensive dictionary build so a
data anomaly degrades gracefully instead of crashing.
**Verify:** unit test `reorderItem` with a duplicated asset id present → no crash,
deterministic order.

### 1.4 — Restore the batch outcome/index contract (G4)
**Problem:** `IngestCoordinator.runBounded` returns `compactMap { results[$0] }`
(`:76`), so a cancelled batch yields fewer outcomes than inputs, breaking the
index-aligned contract (`IngestInput.swift:52`) for the paste/drag path.
**Fix:** return a full-length array with an explicit `.cancelled`/`.skipped`
placeholder for indices with no result, so `zip(inputs, outcomes)` stays aligned.
**Verify:** unit test — cancel mid-batch, assert `outcomes.count == inputs.count`
and positions match.

### 1.5 — De-flake the canvas determinism test (G5)
**Problem:** `SpikeDataTests.deterministic` (`:99`) intermittently fails under
parallel load — CoreGraphics render output varies ±1 per channel.
**Fix (choose after a quick root-cause):** either make the fixture render
deterministic (fixed, non-antialiased fill; avoid gradient dithering), or if the
seed is only meant to govern *layout* (not exact pixels), assert dimensions +
layout equality and drop the exact-pixel compare (update the comment that currently
claims PNG-lossless implies identical pixels — the nondeterminism is upstream in the
*render*, not the encode).
**Verify:** run the full `CanvasRenderer` suite 10× → no failures.

**Phase-1 exit:** all suites green across 10 repeated full runs; changelog written.

---

## Phase 2 — P1 hardening

### 2.1 — Move the capture token to the Keychain (G6)
Replace the `UserDefaults` read/write in `loadOrCreateCaptureToken`
(`IngestionModel.swift:285`) with a Keychain item (generate on first run, read
thereafter). Migrate any existing `UserDefaults` token once, then delete it.
**Verify:** first run creates a Keychain item; relaunch reuses it; the extension
still authenticates.

### 2.2 — Push the canvas thumbnail read off-main (G7) — *profile first*
Per the standing 005 caveat, **profile with Instruments before moving code**. If
pan/zoom janks on a mass cache-miss, make `CanvasContent.imageData(for:tier:)`
(`:91`) async or feed the read through `DecodeScheduler` so the synchronous
`Data(contentsOf:)` leaves the main thread (mirror the Library-side `Task.detached`
in `LibraryView.swift:450`). Keep the main-actor delivery of the decoded image.
**Verify:** Instruments Core-Animation trace shows no main-thread file I/O during a
zoom LOD shift on real variable-size assets.

### 2.3 — Cap `RemoteImageFetcher` before buffering (G8)
Switch `session.data(from:)` (`RemoteImageFetcher.swift:82`) to a streaming
`bytes(from:)` (or check `Content-Length` first) and abort once the 32 MB cap is
exceeded, so a giant URL never fully lands in RAM.
**Verify:** unit test with a mocked oversize response → rejected without full buffer.

### 2.4 — Close the two ledger TOCTOU races (G9)
In `pauseStaleOpenJobs` / `reconcileOrphanedKnownItems` (`AppServices.swift:766,797`)
do the staleness/orphan check **inside the same `pool.write` transaction** as the
mutation (single `UPDATE … WHERE updated_at <= cutoff` / `DELETE … WHERE <predicate>`),
so a job touched in the gap is not wrongly paused/pruned.
**Verify:** unit test that concurrently touches a job during reconcile → it's spared.

### 2.5 — Preserve DB error detail (G10)
Widen `.persistenceFailure` (`AtelierError.swift:65`) to carry the SQLite result
code + message; stop collapsing disk-full/corruption into an opaque case. Replace
`(try? jobItemCounts) ?? [:]` (`IngestionModel.swift:370`) with an error-surfacing
path so a failed sweep reads as an error, not fake-healthy 0/0.
**Verify:** inject a DB error → the surfaced message names the real cause.

**Phase-2 exit:** hardening changelog; no behaviour regressions in the suites.

---

## Phase 3 — Runtime validation (the biggest "green ≠ works" gap)

### 3.1 — Real UI smoke tests (G11)
Replace the `AtelierRefsUITests` template stubs (`:26`) with a handful of XCUITests
driving the actual flows the unit tests can't: launch → tab switch (Canvas/Library/
Sweeps), drop an image, grid select → inspector → Open Original Source, a canvas
pan/zoom, and (with the endpoint up) a single-item capture. Keep them few and
load-bearing.
**Verify:** the XCUITest target runs green in a clean checkout.

### 3.2 — Execute the manual E2E + Instruments passes
Run the [019](./019-bulk-import-verification.md) runbook to completion (the remaining
unticked cases: T3 dedup-with-known-sources-capture, T7 pause-on-wall, T13–T16 popup
glue) and do the canvas Instruments profile that settles G7 with data. Record results
back into 019 and refresh [009](./009-mvp-status-overview.md).

**Phase-3 exit:** doc-019 exit criteria met; 009 updated.

---

## Phase 4 — Distribution edge

### 4.1 — Extension packaging (G12)
Add icon assets (16/32/48/128) + `icons` and `action.default_icon` to
`manifest.json`; add an `npm run package` script that zips only Chrome-needed files
(exclude `test/`, `scripts/`, `node_modules`, fixtures). Bump the version past
`0.1.0`; add `minimum_chrome_version`; narrow `web_accessible_resources` from
`src/*.js` to the modules the loader actually imports.
**Verify:** the produced zip loads unpacked and captures cleanly.

### 4.2 — App distribution (G13)
Decide the channel (Developer ID + notarize for direct distribution, or Mac App
Store). Configure hardened runtime + notarization if Developer ID. **Reconsider the
`macOS 26.5` deployment floor** — lower it to the oldest OS you actually need to
support (Xcode-26 build tooling does not require a 26.x *runtime* target).
**Verify:** a notarized, stapled build launches on a clean machine at the chosen
floor.

### 4.3 — Policy + listing (G14) + id pinning (G17)
Write the privacy disclosure (localhost-only data flow; token; media/provenance to a
local app, never a third party) and reviewer instructions. Decide unlisted vs public
vs unpacked-only, and whether **bulk sweep** ships in the store build at all
(the video-resolution + human-pacing paths are the ToS/"downloader" risk). Once the
published extension id is stable, pass `pinnedExtensionID` into `CaptureAuth`
(`IngestionModel.swift:255`).
**Verify:** submission checklist in [014](./014-publish-readiness-overview.md) fully
ticked.

---

## Phase 5 — Process cleanup (do alongside)

- **Commit the outstanding working tree (G15)** — the popup + scope-filter feature
  (6 untracked src files) and the layout fixes; split into coherent commits.
- **Refresh [009](./009-mvp-status-overview.md) (G16)** to the current changelog head.
- **Operationalize the drift canary (G18)** — a scheduled/cron reminder to run
  `node scripts/drift-check.js` before the ~2-week queryId rotation window, or
  surface staleness in the popup.

---

## Suggested order & rough effort

| Phase | Effort | Why now |
|---|---|---|
| 1 — P0 bugs | ~1 day | Real defects; two bite single-user today |
| 2 — Hardening | ~1–2 days | Security + robustness before any other user |
| 3 — Validation | ~2–3 days | The only way to move "green in CI" → "known to work" |
| 4 — Distribution | ~2–4 days | Mostly packaging/policy, gated on a channel decision |
| 5 — Process | ongoing | Cheap, do in parallel |

**Start here:** Phase 1.1 (G1) and 1.2 (G2) — smallest, highest-value, and both are
bugs that degrade the author's own daily use.

## Verification (whole plan)

- All Swift package suites + `node --test` green, plus a 10× repeat of the
  `CanvasRenderer` suite (flake gate).
- The new XCUITest smoke suite green in a clean checkout.
- The doc-019 manual runbook exit criteria met; canvas Instruments trace captured.
- A notarized app + packaged extension complete one real capture + one bulk sweep on
  a clean machine.
