# 427 — the wall was on the post, not the picture

094 § 9 asked for three device readings in a set order, because the first could end the
project: *can bytes from a logged-in page reach a process that can write a file, affordably?*
It came back yes — by overturning the assumption the question was built on.

Full results in [095](../.docs/095-tier3-spike-results.md). The short of it:

**A session-less native fetch gets the same image.** The control 094 never ran:

```
https://pbs.twimg.com/media/…?format=png&name=orig

from the extension, credentials: "include"   →  200 · 125,523 B · 202 ms
from the native handler, URLSession ephemeral,
     cookies refused, no credential storage  →  200 · 125,523 B · 148 ms · 2.9 MB footprint
```

Byte-identical, through a configuration stricter than `ShareViewController.fetchMedia`'s.
094 § 4 asserted shape 2 "**fails** — cookie-less" and priced the whole seam on it. X's auth
wall is on **reaching the post**, not on **fetching the media** — which is the division of
labour tier 3 already implies: the extension discovers, the native side fetches.

So the design is the cheap one, and it is a path that already exists and is already
measured: a small JSON message carrying provenance and a URL, then
`URLSession.downloadTask` → file → `InboxWriter`. Peak ~3 MB. **S2's thesis — the
extension writes bytes it never held — survives the port intact.**

## What else the readings say

**No fidelity ceiling (094 § 7.1, closed).** Counting the transports apart resolves 425's
unexplained `fetch: 0, XHR: 36`: `fetch=2, xhr=44–61`. The mobile site prefers XHR; there
is no population hiding in a worker, and `hook-core.js:41` wraps both. GraphQL lands at
about one in four parsed responses against 425's one in thirty-six.

**The hook ports unmodified.** `installed=true, readyState=loading` on every run, with
`hook-core.js` copied verbatim out of `extension/src/` — 425 reproduced from the shipping
file rather than a stand-in.

**The ceiling is 80.0 MB, not 120.** `arrival + headroom` sums to 80.0 at every rung on
every run. A Safari web extension's native handler gets two-thirds of what a share
extension gets ([423](423-the-extension-measures-itself.md)). Nothing here can inherit
423's number for a different extension type.

**Shape 1 was measured anyway, and 094 § 4's arithmetic was right.** Peak ÷ payload came
out 2.36–2.38 against a predicted 2.33 (base64 plus the decoded `Data`, 7/3). 16 MB of
payload costs 40.8 MB; 32 MB is killed at ~78 MB against the 80 MB ceiling — the process
dying, not the message being refused. A road not taken, kept because it is the reason not
to take it.

**Two structural facts found by failing.** Native messaging is not exposed to content
scripts (it lives in the background worker), so the chain is one hop longer than 094 § 3
drew it. And a content script cannot fetch the CDN — it runs under the page's origin — which
is why `sw.js:60` has always fetched in the worker.

## Files

Documentation only.

- `.docs/095-tier3-spike-results.md` — new. The readings, the design that follows, and
  what is still open.
- `.docs/094-safari-extension-research.md` — § 4 marked **superseded** by 095 § 4 and kept
  for the record; § 7.1 answered; § 9 marked as run.

The probe stays out of the repo, in the session scratchpad, per 425's precedent: five
builds, `tier3-probe/` + `tier3-native/` + `tier3-xcode/`, with a `RUNBOOK.md`. It was
built to answer three questions and it answered two.

## Migration notes

None — no code changed.

**What this changes for planning.** 091's "+4–6 weeks, gated" is no longer gated, and 094
§ 8's sizing should come down: the bytes row was priced as the gate and is a solved seam
reusing code already written and measured. The one unpriced row, **the trigger**, is now
the only hard problem left. Before a plan doc is written, run the per-host control (095
§ 8.1) — Instagram and Pinterest are unmeasured and RedNote is known walled
([324](324-rednote-is-walled.md)), so at least one host will not fit the rule.
