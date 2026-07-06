# 019 — Bulk Import: Phase 9 Verification Runbook

> Executable, hands-on E2E checklist for [018-bulk-import-plan](./018-bulk-import-plan.md)
> **Phase 9**. Everything up to here is unit-covered (extension 164 / Swift green);
> this phase proves the *browser glue* the tests can't: the SW relay, the durable
> content-script loop, live credentialled fetches, resume-from-checkpoint, and the
> app-side pause/cancel round-trip.
>
> **This is manual.** It needs a running app + Chrome with real logged-in Pinterest
> and X sessions. Work top-to-bottom; each case states its goal, steps, the expected
> result, and what to capture if it fails. Tick the boxes in
> [018 §Phase 9](./018-bulk-import-plan.md) as you go.

---

## Gap 0 — there is no "Start sweep" button *(read first)*

`src/bulk-controller.js` runs the engine when it receives a runtime message
`{ type: "atelier-bulk-start", … }`, but **nothing in the extension sends that
message** — `chrome.action.onClicked` is bound to single-item capture, and there is
no popup. Until a trigger UI exists, every sweep below is launched by hand from the
**service-worker console**.

**Decision (2026-07-05): (a) — run this pass console-driven.** A `sendMessage` from
the SW console delivers the byte-identical message a button would, so (a) leaves
nothing about the pipeline unverified and keeps the E2E run free of fresh, unproven
UI code. **(b)** — a minimal popup / options button that resolves the active tab's
platform + board and sends `atelier-bulk-start` — is deferred to a **follow-up chunk
after** the pipeline is proven green (its own tests: URL→spec resolution + the
board-context extractor). Flagged here so the missing button isn't mistaken for a bug
mid-run.

### How to launch a sweep manually
1. `chrome://extensions` → Atelier → **service worker** → *Inspect* (opens its console).
2. Be on the target tab in the browser (a Pinterest board, or `x.com/i/bookmarks`).
3. Paste, adjusting `input`:

> **Resolve the tab by URL, not `currentWindow`.** From the SW console
> `{ active: true, currentWindow: true }` returns `[]` (the SW has no window) →
> `tab` is `undefined`. Match the target tab by URL instead.

```js
// Pinterest board sweep — boardUrl is the board's path; boardId from the board page.
chrome.tabs.query({}, (tabs) => {
  const tab = tabs.find(t => /pinterest\./.test(t.url || ""));
  if (!tab) { console.log("no pinterest tab open"); return; }
  console.log("target tab:", tab.id, tab.url);
  chrome.tabs.sendMessage(tab.id, {
    type: "atelier-bulk-start",
    platform: "pinterest",
    input: { boardId: "PUT_BOARD_ID", boardUrl: "/username/board-slug/" },
    scope: "board:board-slug",
  }, (r) => console.log("sweep result:", r, chrome.runtime.lastError));
});
```

```js
// X bookmarks sweep — driver ignores `input`; be on x.com/i/bookmarks and let it scroll.
chrome.tabs.query({}, (tabs) => {
  const tab = tabs.find(t => /(twitter|x)\.com/.test(t.url || ""));
  if (!tab) { console.log("no x/twitter tab open"); return; }
  chrome.tabs.sendMessage(tab.id, {
    type: "atelier-bulk-start",
    platform: "twitter",
    input: {},
    scope: "bookmarks",
  }, (r) => console.log("sweep result:", r, chrome.runtime.lastError));
});
```

> If `chrome.runtime.lastError` is *"Could not establish connection. Receiving end
> does not exist"*, the content script isn't on that tab — it was open before the
> extension (re)loaded. **Reload the tab**, then re-run.

> `boardId`: open the board, DevTools console on the page →
> `__NEXT_DATA__` or the network `BoardFeedResource` request's `data` param shows the
> board id; or just read it off any pin's `board.id` in a `BoardFeedResource` response.

---

## Preconditions — one-time setup

- [ ] **P0.1** Build & launch the app (`xcodebuild -scheme AtelierRefs` then run, or
  run from Xcode). Confirm the status line reads "Library ready".
- [ ] **P0.2** Copy the capture **token** from the app UI (the shared-secret field).
- [ ] **P0.3** Load the unpacked extension (`chrome://extensions` → Developer mode →
  *Load unpacked* → `extension/`). Open the extension **Options**, paste the token, save.
- [ ] **P0.4** Sanity: single-item capture still works — right-click any image →
  "Save to Atelier" → it appears in the app. (Proves token + loopback before bulk.)
- [ ] **P0.5** In the app, open the **Sweeps** tab → **grant consent** (own-data-only /
  human-paced / ToS-risk panel). Leave the tab open — it polls the ledger live.
- [ ] **P0.6** Log into Pinterest and X in the same Chrome profile.

### Inspection toolkit (used throughout)

The app is sandboxed; resolve the Library root once:

```bash
# Find the container, then the Library root:
LIB=$(find ~/Library/Containers -maxdepth 5 -type d -name ref-atelier 2>/dev/null | head -1)
echo "$LIB"                       # …/Data/Library/Application Support/ref-atelier
sqlite3 "$LIB/library.sqlite" '.tables'
```

- **Ledger state** (job + per-item outcomes):
  ```bash
  sqlite3 -header -column "$LIB/library.sqlite" \
    "SELECT id, platform, status FROM job ORDER BY rowid DESC LIMIT 5;"
  sqlite3 -header -column "$LIB/library.sqlite" \
    "SELECT status, COUNT(*) FROM job_item WHERE job_id='JOB_ID' GROUP BY status;"
  ```
- **Blob count on disk** (dedup ground truth): count files under the MediaStore blob
  dir inside `$LIB` (`find "$LIB" -type f -name '*.png' -o -name '*.jpg' … | wc -l`,
  or count the content-addressed blob dir specifically).
- **Checkpoint** (`chrome.storage.local`): SW console →
  `chrome.storage.local.get(null, (o) => console.log(o))` — look for the sweep's
  `checkpointKey` entry (cursor + committed watermark).
- **Console logs**: the content-script `log()` output shows on the **page** tab's
  DevTools console; relay/SW errors show on the **service-worker** console.

---

## Test cases

### T1 — Happy path: small Pinterest board *(the load-bearing case)* — ✅ DONE (2026-07-06)
**Goal:** a whole small board (≈10–30 pins) ingests once, cleanly.
**Result:** closed during the T5 run — a **76-pin board** (spans ~3 BoardFeedResource
pages, so the paginator is exercised) ingested **76/76 → `complete`**, 76 assets = 76
distinct blobs = 76 sources, 0 partials. The full multi-page happy path is proven.
> **Superseded partial (2026-07-05):** first pass was a single-pin board (`ingested: 1`),
> which proved only the item happy-path, not pagination. The 76-pin run covers it.
- [ ] Launch the Pinterest sweep (Gap 0). Watch the Sweeps tab count climb.
- [ ] **Expect:** every pin lands; `job.status` ends `complete`; ingested count ==
  board's pin count; `sweep result: { ok: true, result: { status: "complete" … } }`.
- [ ] **Expect:** blob count on disk == distinct media count (no partials/dupes).
- **On failure capture:** the `sweep result` object, page-console `log()` tail, SW
  console errors, and `SELECT status,COUNT(*) … GROUP BY status`.

### T2 — Provenance correctness — ✅ DONE (2026-07-06, data-verified)
**Goal:** ingested assets carry the right origin metadata.
**Result:** 76 ingested Pinterest sources checked. Each carries `platform=pinterest`,
`original_url` = the canonical pin URL (`https://REDACTED/pin/{id}/`), and
`author_handle`/`author_name` (`sujenphea0843` / `sujen`). The media URL isn't
persisted (transient download detail — the `toOriginals` rewrite is extension-unit
covered), so verified indirectly via **dimensions**: widths span 300–7500px (avg 1260),
many >736 — Pinterest's thumbnail ladder caps at 736 (236/474/736), so anything wider
must be the `/originals/` fetch; the small ones aren't ladder values either → true
originals. No thumbnail-size assets present.
- [x] platform / `original_url` / author fields correct; media = originals.

### T3 — Dedup-skip (re-run → zero re-downloads)
**Goal:** re-sweeping the same board downloads nothing new.
- [ ] Re-launch the **same** board sweep.
- [ ] **Expect:** Sweeps tab shows ingested≈0, skipped≈all; **blob count unchanged**;
  `job_item` for the new job is dominated by `skipped`/dedup outcomes.
- [ ] **Expect** the known-sources call fired: SW console shows the
  `GET /jobs/{id}/known-sources` returning the prior source ids.
- **On failure:** if blobs grew, dedup broke — capture the two blob counts and the
  known-sources response body.

### T4 — Resumability: kill the tab mid-sweep — ✅ DONE ([changelog 066](../.change-log/066-bulk-checkpoint-stable-key.md))
**Result (2026-07-06):** first pass exposed that the checkpoint was keyed by `jobId`,
so a re-run (new job) never read the saved cursor — it re-enumerated + dedup-skipped
(correct, wasteful) and leaked a checkpoint per run. Fixed to a **stable per-board
key** (`atelier:bulk:${platform}:${boardId}`), cleared on clean completion. Re-verified
on test3: kill → exactly the stable key present → re-run resumed → completed → key
removed.
**Goal:** interrupting the page, then re-sweeping, resumes without duplicates.
- [ ] Start a sweep on a **larger** board; ~⅓ through, **close the tab**.
- [ ] Note the checkpoint (`chrome.storage.local.get`) — cursor + watermark present.
- [ ] Reopen the board, relaunch the sweep.
- [ ] **Expect:** it resumes near the checkpoint (re-fetches the boundary page, dedup
  absorbs the overlap), finishes `complete`, **blob count == full board, no dupes**.
- **On failure:** capture the checkpoint before/after and the final blob count vs
  board size.

### T5 — SW-death resilience: kill the SW mid-sweep *(the Phase-6 verify criterion)* — ✅ DONE (2026-07-06)
**Goal:** the durable content-script loop survives the ephemeral SW.
**Result:** swept a 76-pin board; killed the SW mid-run via `chrome://serviceworker-internals`
**Stop** (Chrome immediately re-spawns it on the next relay — the "keeps restarting"
is the pass signal, and the SW console clearing on each respawn is just the fresh
worker context, not a reset). The loop ran to completion regardless: job `complete`,
`ingested_count = 76`, `job_item` = **76 ingested / 0 skipped / 0 failed**, 76 assets =
76 distinct blobs (no dupes) = 76 sources, **0 not-fully-downloaded** (no partials).
- [x] Loop survives SW termination; full board lands `complete`, no partial/dupe.
> **Note (kill *once*):** repeatedly Stopping just re-clears the SW console and proves
> nothing new — one kill establishes the resilience.
> **Incidental T3 signal:** two re-launches after the 76 landed produced `complete`
> jobs with `ingested_count = 0` and zero `job_item` rows — the whole board was already
> known, so every source was download-skipped. (Formal T3 still wants the
> known-sources call captured, but the dedup outcome is confirmed.)

### T6 — App-side pause / resume / cancel *(the "full working controls" decision)*
**Goal:** the app buttons actually halt/resume a *running* browser sweep via the
per-item relay reply (`CaptureResponse.jobStatus` → `classifyIngestResult` halt).
**Parts A + B ✅ DONE (2026-07-06)** — exposed and fixed two bugs before passing:
- **Pause closed a dead "Stopped" job** (no Resume button): the controller always sent
  `/complete status=halted`, clobbering the app's `paused`. Fixed [069](../.change-log/069-pause-closes-resumable.md)
  — Pause now closes `paused` (resumable), Cancel stays `halted`, wall self-halts `paused`.
- **Resume minted a NEW job** → two ledger rows + a transient zombie `open`. Fixed
  [070](../.change-log/070-resume-continues-same-job.md) — the checkpoint carries the
  jobId and the server reopens that job.
- [x] Pause → `sweep result status:"halted"`, Sweeps tab shows **Paused** + Resume.
- [x] Resume + re-run → resumes from checkpoint, **one job** `a03d1f4a` ends `complete`
  with `ingested_count = 76` (15 paused + 61 resumed), 76 assets = 76 blobs, no dupes.
- [x] **Part C — Cancel ✅ (2026-07-06):** hit **Cancel** mid-sweep → `sweep result`
  `status:"halted"`, `haltStatus:"halted"`; job `18f0b8eb` = **halted** (terminal,
  "Stopped"), `ingested_count = 10` (the pre-cancel items stayed — Cancel stops future
  work, doesn't roll back). Checkpoint-clear on cancel is unit-covered (069) — a later
  re-sweep starts fresh from page 1.
- **On failure:** capture the `jobStatus` on the last relay reply and the `job.status`
  the app wrote — the halt rides that one field.

### T7 — Pause-on-wall (429 / DOM wall)
**Goal:** a real rate-limit or an interstitial pauses gracefully, and is resumable.
- [ ] Provoke or wait for a 429 / login-wall / empty-guard during a sweep (a large
  board or fast re-runs). If hard to provoke naturally, note it as *observed if seen*.
- [ ] **Expect:** the engine backs off then halts cleanly (no crash, no partial
  asset); state is checkpointed; a later relaunch resumes.
- **On failure:** capture the failing network response and the engine's `counts`
  (retryableFailed vs permanentFailed) from the `sweep result`.

### T8 — Progress accuracy — ✅ DONE (2026-07-06, data-verified)
**Goal:** the Sweeps tab numbers match reality.
**Result:** on the healthy completed job (7aaf6d4c), all four counts coincide:
`ingested_count` = 56 == known `job_item`s (56) == distinct `blob_hash`es (56) ==
present `asset` rows (56). No drift. Bonus: jobs whose assets were later deleted read
`ingested_count = 0` with zero `job_item` rows — the delete-forget recompute (065)
keeps the polled count column truthful rather than leaving a stale high-water mark.
- [x] ingested == blobs == assets; count column stays consistent post-delete.

### T9 — X bookmarks sweep (interception path) — ✅ DONE (2026-07-06)
**Goal:** the MAIN-world hook + push→pull source ingest a bookmarks set.
**Result:** worked only after **three fixes flushed out live** (the X path had never run
end-to-end): [071](../.change-log/071-twitter-hook-classic-script.md) — the hook file
had top-level `export`, a SyntaxError that killed the classic MAIN-world injection;
[072](../.change-log/072-twitter-hook-xhr-transport.md) — X pulls the timeline over
**`XMLHttpRequest`, not `fetch`** (confirmed live via an XHR probe), so the fetch-only
hook captured nothing. After both, a bookmarks sweep ingested **64** assets, paused
cleanly (`haltStatus:"paused"`, resumable) with a real bookmarks `cursor`.
- [x] Enumerates + ingests; `job.status` transitions correctly (069/070 hold on X too).
- [x] Provenance correct: `platform=twitter`, canonical `x.com/{handle}/status/{id}`
  URLs, `@handle`, tweet text; a 3-photo tweet → **3 assets** (one per `mediaKey`);
  quoted media excluded.
- Video→poster path not hit live (recent bookmarks were all photos) — stays unit-covered.
> **Diagnosis note:** the fetch hook installing (`__atelierTimelineHookInstalled`) was a
> red herring — the real transport was XHR. Root-caused by probing
> `XMLHttpRequest.prototype.open` on the live page, not by guessing.

### T10 — Pinterest live header sufficiency *(deferred Phase-0 recon)* — ✅ DONE ([changelog 064](../.change-log/064-pinterest-pws-handler-403-fix.md))
**Result (2026-07-05):** the driver's original header set **403'd live** (as Phase-0
warned). Bisected the real request header-by-header against the running board:
**`x-pinterest-pws-handler` is the sole 403 gatekeeper** (value
`www/[username]/[slug].js`, a literal board-route constant) — `X-APP-VERSION` /
`csrftoken` / `accept` / `appstate` / `source-url` are not the trigger. Driver now
derives `pws-handler` per resource; re-sweep → `complete`, `error: null`, no 403.

### T11 — Drift canary against a live capture *(keeps the fixtures honest)*
- [ ] Save a fresh live `Bookmarks` response and a `BoardFeedResource` response into
  the gitignored `resources/` (via DevTools "Copy response" or Claude-in-Chrome).
- [ ] Run:
  ```bash
  cd extension
  node scripts/drift-check.js --x ../resources/live-bookmarks.json
  node scripts/drift-check.js --pinterest ../resources/live-boardfeed.json
  ```
- [ ] **Expect:** exit 0, no drift. If it flags drift, the live shape moved — update
  the parser + `drift-baseline.json` markers (X queryId, Pinterest app-version) and
  the committed fixtures.

---

## Exit criteria
Phase 9 is done when **T1–T9 pass** and **T10–T11 are green or explicitly noted**.
Then:
- [ ] Tick the sub-boxes in [018 §Phase 9](./018-bulk-import-plan.md).
- [ ] Write `.change-log/064-…` recording the E2E result (which cases passed, any
  observed walls, whether the start-trigger gap was closed).
- [ ] Update [009-mvp-status-overview](./009-mvp-status-overview.md) — the bulk path
  has landed.

## If something fails
Per the standing rule: **verify the real root cause on real data before fixing** —
capture the concrete failing response / ledger row / console tail named in each case,
reproduce the exact request, and fix the specific seam (mapper, header, relay,
checkpoint). Don't patch around a symptom.
