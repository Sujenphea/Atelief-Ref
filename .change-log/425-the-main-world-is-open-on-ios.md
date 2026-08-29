# 425 — the MAIN world is open on iOS

091's open question 1 — **does Safari on iOS support `world: "MAIN"` content scripts at
`document_start`?** — is answered: **yes**, on iOS 26. Tier 3 is not blocked.

The question has sat open since 091 was written because the entire tier-3 case rests on
it. `hook-core.js` / `twitter-hook.js` reach current capture fidelity by wrapping
`fetch`/`XMLHttpRequest` BEFORE the page's own scripts run and reading GraphQL bodies out
of the responses. No MAIN world at `document_start`, no hook, and tier 3 collapses back to
tier 2 — which is what the phone already has.

## What was measured

A throwaway Safari Web Extension: one MAIN-world content script at `document_start`, one
ISOLATED script at the same time as its control. Run on a device against a logged-in
x.com. It reports **functionally** rather than by feature detection — "MAIN world is
supported" is a claim, "it intercepted 36 of the page's own requests" is an observation.

| reading | value | means |
|---|---|---|
| `readyState` when injected | `loading` | it ran BEFORE the page's scripts — the `document_start` guarantee the hook needs |
| isolated relay could see MAIN globals | **no** | the worlds are genuinely separate; `world` was honoured, not ignored |
| fetch intercepted | 0 | — |
| XHR intercepted | **36** | the hook is in front of real traffic |
| graphql | 1 | the payloads `twitter-hook.js` reads do pass through |

The relay is the row that matters most. A script declared ISOLATED that CAN see the MAIN
world's globals would mean Safari ran both together and ignored `world` — a hook that
"works" while sitting in the page's own world is visible to the page and is not a port. It
could not see them.

## Apple's converter is wrong about this

`xcrun safari-web-extension-converter` warns:

> The following keys in your manifest.json are not supported by your current version of
> Safari: **`world`**

It is a static check against a key list, and it is stale. The key works. This is the
entire reason the probe was built as a functional test rather than accepting the tooling's
answer — and the reason to distrust that warning next time it appears.

## The one unexplained reading

`fetch: 0` while `XHR: 36`. Not a blocker — `hook-core.js` already wraps **both**
(`hook-core.js:41`), so the path the traffic actually took is covered. But it is not
understood, and two explanations have different consequences for fidelity:

- the mobile site simply uses XHR where the desktop site uses `fetch` — harmless; or
- the `fetch` calls happen inside a **worker**, which a MAIN-world page hook does not
  reach — which would mean some payloads are invisible on iOS in a way they are not on the
  desktop.

`graphql: 1` out of 36 requests is also a thin sample; the page was mostly loading media
(the first intercepted URL was a video). A timeline scroll would exercise the GraphQL path
properly. **Neither is answered here, and neither needs to be to unblock the work** — they
belong to the Safari-extension research doc 091 says comes next.

## Status change

091 open question 1: **answered, yes.** The Safari Web Extension port ("+4–6 weeks,
gated") is no longer gated. What it now needs is the research doc 091 already names as its
follow-on, not another feasibility probe.

## Files

Documentation only. The probe itself is disposable and deliberately uncommitted — it lives
in the session scratchpad as `tier3-probe/` (the web extension) and `tier3-xcode/` (the
converted Xcode project). It was built to answer one question once; the port will not
start from it.
