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

### T1 — Happy path: small Pinterest board *(the load-bearing case)*
**Goal:** a whole small board (≈10–30 pins) ingests once, cleanly.
> **Partial (2026-07-05):** ran green against a **single-pin** board →
> `complete`, `ingested: 1`. That proves the item happy-path but NOT pagination /
> cross-page dedup / resume (T3/T4). **Re-run on a ≥2-page board** (>25 pins) to cover
> the paginator before ticking this.
- [ ] Launch the Pinterest sweep (Gap 0). Watch the Sweeps tab count climb.
- [ ] **Expect:** every pin lands; `job.status` ends `complete`; ingested count ==
  board's pin count; `sweep result: { ok: true, result: { status: "complete" … } }`.
- [ ] **Expect:** blob count on disk == distinct media count (no partials/dupes).
- **On failure capture:** the `sweep result` object, page-console `log()` tail, SW
  console errors, and `SELECT status,COUNT(*) … GROUP BY status`.

### T2 — Provenance correctness
**Goal:** ingested assets carry the right origin metadata.
- [ ] After T1, pick 3 assets in the app inspector (one multi-image pin, one plain).
- [ ] **Expect** each: platform=pinterest, correct `originalURL` (the pin URL),
  author handle/name, and media URL pointing at the `/originals/` rewrite (not a
  thumbnail size segment).
- **On failure:** note which field is wrong vs the live pin; that isolates
  `mapPinterestPin` / `toOriginals` / `makeProvenance`.

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

### T5 — SW-death resilience: kill the SW mid-sweep *(the Phase-6 verify criterion)*
**Goal:** the durable content-script loop survives the ephemeral SW.
- [ ] Start a board sweep. Mid-run, on `chrome://extensions`, click **service worker →
  terminate** (or just wait for its ~30s idle death between items).
- [ ] **Expect:** the loop keeps going — the next item's relay call transparently
  re-wakes the SW; the sweep still finishes `complete`. Page console `log()` keeps
  advancing across the termination.
- **On failure:** if the loop stalls, capture the page console at the stall and
  whether the SW re-spawned on the next relay.

### T6 — App-side pause / resume / cancel *(the "full working controls" decision)*
**Goal:** the app buttons actually halt/resume a *running* browser sweep via the
per-item relay reply (`CaptureResponse.jobStatus` → `classifyIngestResult` halt).
- [ ] Start a board sweep. Mid-run, hit **Pause** in the Sweeps tab.
- [ ] **Expect:** within one item the loop halts (`sweep result … status:"halted"`);
  blob count stops climbing; `job.status` = paused.
- [ ] Hit **Resume**, relaunch the sweep → it continues from checkpoint to `complete`.
- [ ] Repeat with **Cancel** → sweep halts and `job.status` reflects the cancel; a
  relaunch does *not* silently re-ingest a cancelled job's remainder unless intended.
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

### T8 — Progress accuracy
**Goal:** the Sweeps tab numbers match reality.
- [ ] After any completed sweep, compare the tab's ingested / skipped / failed against
  `job_item` GROUP BY and the on-disk blob delta.
- [ ] **Expect:** ingested == new blobs; ingested+skipped+failed == items enumerated;
  no drift between the polled view and the ledger.

### T9 — X bookmarks sweep (interception path)
**Goal:** the MAIN-world fetch hook + push→pull source ingest a small bookmarks set.
- [ ] Go to `x.com/i/bookmarks`, launch the twitter sweep (Gap 0). Let the page
  auto-scroll.
- [ ] **Expect:** one asset per top-level media (quoted-tweet media excluded); videos
  land as poster (or MP4 if `resolveVideo`); ends on a 0-tweet page; `complete`.
- [ ] Spot-check provenance (T2-style) on 2–3 X assets: handle, tweet URL, media host
  (`pbs.twimg` image vs `video.twimg`).
- **On failure:** capture a `read_network_requests`/DevTools view of the intercepted
  `Bookmarks` GraphQL response and the mapped `sweep result` counts.

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
