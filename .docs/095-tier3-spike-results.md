# 095 — tier-3 spike: results

> The device readings [094](094-safari-extension-research.md) § 9 asked for, taken
> 2026-08-25 on an iPhone on iOS 26 against a logged-in x.com, with a throwaway Safari Web
> Extension built for the purpose. Three readings were specified in order, because the
> first could end the project. **It did not. It came back in the cheap direction, and it
> did so by overturning the assumption the whole seam rested on.**

## The one-line answer

**Tier 3 is worth building, and the bytes problem 094 § 4 was built around does not exist.**
X's media CDN serves the same bytes to a session-less `URLSession` that it serves to the
page, so the extension never has to carry an image through a message. The auth wall is on
**discovering** the media URL, not on fetching it — and discovering it is exactly what the
hook is for.

094 § 9's stop condition was *"if neither shape carries auth-walled bytes affordably, stop"*.
Shape 2 carries them at 2.9 MB.

---

## 1. What was measured

A disposable extension: `hook-core.js` copied **verbatim** out of `extension/src/`, a
MAIN-world installer, an ISOLATED relay, a background service worker, and a native handler
that reports its own `phys_footprint` using `ShareViewController.footprint()` unchanged —
so every number below sits on the same scale as
[423](../.change-log/423-the-extension-measures-itself.md)'s.

Readings taken over five builds; the ladder ran three times and reproduced.

## 2. Reading 3 — the fidelity ceiling. **There isn't one.**

425 measured `fetch: 0, XHR: 36` and could not say whether the mobile site simply prefers
XHR (harmless) or whether `fetch` calls happen inside a **worker** a page hook cannot reach
(a fidelity ceiling iOS would have and the desktop would not). Counting the transports
separately settles it:

| run | `fetch` | `xhr` | parsed responses | `graphql` |
|---|---:|---:|---:|---:|
| build 4 | 2 | 61 | 18 | 4 |
| build 5 | 2 | 44 | 13 | 3 |

`fetch` is not zero — it is small, because the site uses XHR for almost everything. There
is no hidden population. And `hook-core.js:41` wraps **both**, so the hook is in front of
all of it: GraphQL bodies land at roughly one in four parsed responses, against 425's
one in thirty-six.

**094 § 7.1 is closed.** The mobile site's transport mix is a fact about the site, not a
ceiling on the port.

Also confirmed, and it is the load-bearing one: `installed=true`, `readyState=loading`, on
every run, with `hook-core.js` **unmodified**. 425 reproduced from the shipping file rather
than a stand-in.

## 3. Reading 1a — the session. **The extension has it.**

```
GET https://pbs.twimg.com/media/…?format=png&name=orig
credentials: "include"   →   HTTP 200 · 125,523 B · image/png · 202 ms
```

First attempt, no fallback needed, `twimgGranted: true`.

## 4. Reading 1c — the control, and the finding

094 § 4 stated as fact that shape 2 "**fails** — cookie-less". It was never tested. It is
wrong, at least for the host that matters most:

```
same URL, handed to the native handler
URLSession: ephemeral · cookies refused · no credential storage · downloadTask
                        →   HTTP 200 · 125,523 B · image/png · 148 ms
```

**Byte-identical to the credentialed fetch.** A session-less native fetch, through a
configuration deliberately stricter than `ShareViewController.fetchMedia`'s plain
`URLSession.shared`, gets the same image.

So the auth wall on X is on **reaching the post** — which needs the page, the session, and
the GraphQL body — and not on **fetching the media** once its URL is known. Which is
precisely the division of labour tier 3 already implies: *the extension discovers, the
native side fetches.*

## 5. Reading 1b — the ladder, which is now a fact about a road not taken

Shape 1 (bytes through the message) was measured anyway, and it behaves exactly as
094 § 4 predicted:

| payload | arrival | peak | ok |
|---|---|---|---|
| 256 KB | 3.2 MB | 3.3 MB | yes |
| 1 MB | 3.8 | 4.6 | yes |
| 4 MB | 8.2 | 12.3 | yes |
| 8 MB | 13.5 | 21.6 | yes |
| 16 MB | 24.8 | **40.8** | yes |
| 32 MB | — | — | **killed** |

Fit the slope over the top of the ladder, on both runs:

| | run 2 | run 3 | theory |
|---|---:|---:|---|
| arrival ÷ payload | 1.367 | 1.383 | **4/3** — the base64 string, resident |
| peak ÷ payload | 2.358 | 2.375 | **7/3** — base64 *plus* the decoded `Data` |

094 § 4 guessed "~2.33×". It measured 2.36–2.38.

**Two facts to keep even though the shape is not being built:**

- **The ceiling is 80.0 MB, not 120.** `arrival + headroom` sums to 80.0 at every rung on
  every run. A Safari web extension's native handler gets **two-thirds** of what a share
  extension gets (423's 120.0 MB). Nothing in this project can inherit 423's ceiling for a
  different extension type.
- **32 MB dies the way memory dies**, not the way a message limit does: *"Couldn't
  communicate with a helper application"* after ~1.2 s, `handler: null`. Projected peak at
  32 MB is 2.37 × 32 + 2.3 ≈ **78 MB against 80**. The boundary never refused anything —
  the process was killed holding it. The usable ceiling for shape 1 would have been ~24 MB,
  well under `InboxWriter.maximumPayloadBytes`'s 64 MiB.

**Side effect worth carrying into the plan:** at one rung `arrival` read 18.4 MB, higher
than that rung's own peak. The handler process is **reused between messages and does not
reclaim promptly**, so consecutive captures accumulate against the 80 MB ceiling. Harmless
at 3 MB a capture; it would not have been harmless at 40.

## 6. Two structural facts found by failing

Both cost a device run, and both are architecture rather than trivia.

**Native messaging is not exposed to content scripts.** `browser.runtime.sendNativeMessage`
is `undefined` there and a `function` in the background worker — reported by the probe
itself (`capabilities`) once it knew to ask. Same rule as Chrome; not an iOS quirk. So the
chain is one hop longer than 094 § 3 drew it, recorded there.

**A content script cannot fetch the CDN.** It runs under the *page's* origin, so reading
bytes off `pbs.twimg.com` is a cross-origin read the CDN never granted — `TypeError: Load
failed`, twice, until the fetch moved into the worker, which fetches on `host_permissions`
instead of an origin. This is not a discovery so much as a rediscovery: `sw.js:60` has
always done it in the worker.

## 7. The design that follows

```
MAIN world hook (hook-core.js, unmodified)
    intercepts GraphQL → provenance + the media URL
  →postMessage→  ISOLATED content script
  →runtime.sendMessage→  background service worker
  →sendNativeMessage→  SafariWebExtensionHandler        ← a SMALL JSON. No bytes.
       URLSession.downloadTask → file → InboxWriter
  →  inbox/  →  InboxArchive  →  AirDrop  →  Mac        ← all of this already exists
```

The message carries a `CaptureRequest`-shaped payload and a URL. Peak footprint ~3 MB
against an 80 MB ceiling. No chunking, no base64, no cap worth arguing about — and the
native half is the path `ShareViewController.fetchMedia` → `download(from:)` → `adopt`
already takes, already measured at 0.2 MB for 16.3 MB.

**S2's thesis survives the port intact:** the extension writes bytes it never held.

## 8. What is still open

1. **Per-host.** This is X. Instagram and Pinterest CDNs have not been put through
   reading 1c, and **RedNote is known to be walled**
   ([324](../.change-log/324-rednote-is-walled.md)) — so at least one host will need
   shape 1 or nothing. Run the control per host before the plan commits to "native
   fetches" as a universal rule.
2. **URL lifetime.** A signed or expiring CDN URL makes "fetch later on the native side" a
   race the desktop never had to think about, because it fetched immediately. Unmeasured.
3. **Reading 2 — persistence.** Unrun, and only needed if the share sheet stays the
   trigger (094 § 2's third candidate). It needs a third process and an App Group.
4. **The trigger.** Untouched by any of this, and now the *only* hard problem left. The
   probe's in-page panel is a working instance of 094 § 2's second candidate and behaves
   exactly as that section feared: it draws over the feed, it is styled against nothing,
   and it would break on a redesign.

## 9. Recommendation

**Tier 3 is a go, and 094 § 8's sizing should be revised down** — the bytes row was priced
as the gate and is now a solved seam that reuses code already written and measured. What
091 called "+4–6 weeks, gated" is no longer gated, and the estimate's one unpriced row is
the trigger, which is where the remaining design effort actually is.

Next doc is a plan, not more research. Before it is written, run § 8.1 — the per-host
control — because it is one tap per host and it decides whether the design in § 7 is the
rule or merely the common case.
