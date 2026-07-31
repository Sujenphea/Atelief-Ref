# 301 — Extension: discover the app's loopback port instead of assuming it

## Summary

Reported as `TypeError: Failed to fetch` on an Instagram sweep. Not an Instagram
problem, and nothing to do with the sweep logic: the extension hard-coded
`http://127.0.0.1:47321`, and the **dev** app listens on **47322**.

299 gave the Debug build its own bundle id (`sujenphea.AtelierRefs.dev`) and, so
the two builds don't race for one bind, `IngestionModel.capturePort(bundleID:)`
offsets a `.dev` bundle to `defaultPort + 1`. 299 noted "the shipping bundle must
keep 47321 (the extension's value)" — true, but it left the case where the
shipping build ISN'T the one running. With only the dev app up, nothing is on
47321, and Chrome reports a refused connection as the opaque
`TypeError: Failed to fetch`.

Confirmed at the time of the report:

```
47321 → curl: (7) Couldn't connect to server
47322 → {"status":"error","error":"Missing or invalid token."}   (HTTP 403 — app is up)
```

A sweep opens with `POST /jobs` (`bulk-sw.js` → `bulk-endpoint.js`), so it died on
its very first call. Single-item capture had the identical bug — it just hadn't
been exercised.

## The fix

`src/base-url.js` resolves the host per request instead of assuming it:

- **Probe** `GET /health` on 47321 then 47322; first to answer wins. "Answers"
  means ANY HTTP response including 401/403 — `/health` is token-gated, so a
  403 still proves the app is listening. Only a thrown fetch means nothing there.
- **Stable first**, deliberately: 299's rule is that the shipping bundle owns
  47321, so when both apps are up the shipping one receives.
- **Cached** in `chrome.storage.local`, so a sweep pays the probe once rather
  than per item.
- **Self-healing**: `withBase` retries once against a re-probed host on a NETWORK
  failure only. Quit the stable app mid-session and start the dev one and the
  next call finds it. An app-level error (`open job failed (HTTP 409)`) is NOT a
  reason to hunt for a port and propagates untouched.
- **Overridable**: the options page gains a Stable / Dev / Auto selector for when
  both are running and you want a specific target. Saving it also clears the
  cached probe result, so the change takes effect immediately.

With nothing reachable, `resolveBase` returns the first candidate rather than
throwing, so the caller's own request produces the real, attributable error
instead of the resolver inventing one.

## Files changed

**New**

- `extension/src/base-url.js` — candidates, `candidateOrder`, `isNetworkError`,
  `probeBase`, `resolveBase`, `invalidateBase`, `withBase`, and a `{load, save,
  remove}` storage shim matching `bulk-controller.makeChromeStorage`.
- `extension/test/base-url.test.js` — 16 cases: stable-first precedence, dev-only
  discovery (the reported bug), caching, the pinned override, the network-error
  retry, and the "app answered unhappily → do not retry" case.

**Changed**

- `extension/src/bulk-endpoint.js` — `jobFetch` resolves the base through
  `withBase`; `storage` threaded through `openJob` / `fetchKnownSources` /
  `completeJob` for injection.
- `extension/src/sw.js` — `defaultDeps.postCapture` and the video ingest both
  wrapped in `withBase`, so single-item capture is fixed too.
- `extension/src/options.html` / `options.js` — the target selector; `options.js`
  is now `type="module"` so it imports the storage keys from `base-url.js` rather
  than restating them.
- `extension/src/endpoint.js` — `DEFAULT_BASE` kept as the helpers' default, with
  a note that production callers pass a resolved `endpoint:` instead.
- `extension/README.md` — documents the discovery.
- `extension/test/bulk-endpoint.test.js` — each test now injects a store with the
  base pre-resolved, so it asserts the `/jobs` request rather than the `/health`
  probe in front of it. These were previously order-dependent through a shared
  module-level cache; now they aren't.

## Verification

`npm test` in `extension/`: 395 pass, 0 fail (was 379 before; one existing test
was updated as described above).

Resolution checked against the **live** running dev app, not a mock:

```
resolved base : http://127.0.0.1:47322
GET /health   : 403   (app is up, token-gated)
```

Stable-first precedence with BOTH apps running is covered by unit test only — the
stable build in `/Applications` was not launched, since that opens the real
768 MB library.

The Instagram sweep itself was not re-run end to end; that needs a logged-in
browser session and is the obvious next check.

## Notes

- `manifest.json` already grants `http://127.0.0.1/*` (all ports), so no
  permission change was needed.
- `PRIVACY.md` still says 47321. That remains correct for the shipping extension
  talking to the shipping app, which is what the store listing describes.

## Follow-up: `POST /jobs → 403` after the port fix

With the port resolved, `/health` returned 200 (token good) but `POST /jobs`
returned 403. That is `JobRoutes.handleCreateJob`'s consent gate
(`JobRoutes.swift:51` → `consent_required`), not a regression:

```
sujenphea.AtelierRefs:      AtelierBulkConsentGranted = 1
sujenphea.AtelierRefs.dev:  (key not set → false)
```

Same root cause family as the port itself. 299 gave the dev build its own sandbox
container, and `UserDefaults` lives in that container — so the bulk-import consent
accepted in the stable app does not carry over. 299's migration notes call out the
empty library but not the reset defaults; consent is the one that blocks a sweep.

**Resolution:** accept the notice in the dev app — sidebar → **Capture** → **Bulk
Import Sweeps…** → **"I understand — enable bulk import"**. Deliberately not
scripted around by writing the defaults key: it is a consent click, and it is the
user's to make.

The server's 403 body already carries the right message ("Bulk import is off. Open
ref-atelier and accept the bulk-import notice to enable it."), which `openJob`
rethrows, so the extension surfaces it — no extension change needed.
