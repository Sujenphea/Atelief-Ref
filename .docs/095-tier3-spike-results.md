# 095 — tier-3 spike: results

> The device readings [094](094-safari-extension-research.md) § 9 asked for, taken
> 2026-08-25 on an iPhone on iOS 26 against logged-in x.com, instagram.com and
> pinterest.com, with a throwaway Safari Web Extension built for the purpose. Three
> readings were specified in order, because the first could end the project. **It did not.
> It came back in the cheap direction, and it did so by overturning the assumption the
> whole seam rested on.**

## The one-line answer

**Tier 3 is worth building, and the bytes problem 094 § 4 was built around does not exist.**
All three live platforms' media CDNs serve the same bytes to a session-less `URLSession`
that they serve to the page — X, Instagram (signed URLs included) and Pinterest, verified
byte-for-byte (§ 8). So the extension never has to carry an image through a message. The
auth wall is on **discovering** the media URL, not on fetching it — and discovering it is
exactly what the hook is for.

094 § 9's stop condition was *"if neither shape carries auth-walled bytes affordably, stop"*.
Shape 2 carries them at **2.9–3.1 MB, flat across every host and every size**, because it
is a file copy and file copies do not scale.

---

## 1. What was measured

A disposable extension: `hook-core.js` copied **verbatim** out of `extension/src/`, a
MAIN-world installer, an ISOLATED relay, a background service worker, and a native handler
that reports its own `phys_footprint` using `ShareViewController.footprint()` unchanged —
so every number below sits on the same scale as
[423](../.change-log/423-the-extension-measures-itself.md)'s.

Readings taken over seven builds; the ladder ran four times and reproduced, and the § 4
control ran on three platforms.

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

## 8. Per-host — run 2026-08-25, all three live platforms

The control was repeated on Instagram and Pinterest. **It holds everywhere.**

| host | with session | no session | native footprint | url |
|---|---|---|---|---|
| **x.com** | 200 · 125,523 B | **200 · 125,523 B** | 2.9 MB | plain, `name=orig` |
| **instagram** | 200 · 52,422 B | **200 · 52,422 B** | 3.0 MB | **signed** (`oh=`/`oe=`) |
| **pinterest** | 200 · 116,340 B | **200 · 116,340 B** | 3.1 MB | plain, `/originals/` |

Byte-identical on every host, and **the native footprint is flat at 2.9–3.1 MB regardless
of platform or payload** — it is a file copy, so it does not scale with the image. That is
the whole argument for shape 2, and it is now measured three times rather than reasoned
about once.

**Instagram signs its URLs and it does not matter.** The signature is on the URL, not on
the cookie jar: a session-less `URLSession` presenting the same signed URL gets the same
bytes. It also settles the URL-lifetime worry — `oe=6A92F98C` decodes to
**2026-08-29T15:23Z, about 99 hours out**. "The native side fetches later" is not a race at
any timescale a capture lives on; only an archive left unimported for four days would find
a dead URL, and by then the bytes are already in the inbox.

**Pinterest 403'd first, and it was not an auth wall.** `/originals/` returned
`403 · 263 B · application/xml` — *identically with and without the session*, which is the
control answering in the clearest way available: the CDN does not look at credentials at
all. It was a pin whose original Pinterest had not kept, exactly as
`extractors/pinterest.js:37` documents ("`/originals/` can 404 … the rendered size is kept
as a fetch fallback"). The probe had rewritten to `/originals/` with no fallback; the
shipping extractor never would. **Transcribing the extractors' fallback chains rather than
inventing a rewrite is load-bearing** — a probe without them reads a missing file as a dead
platform. A second pin, which did have an original, returned 200 on the first try.

**RedNote was not run** and is known walled ([324](../.change-log/324-rednote-is-walled.md)).
It is the one host § 7's design should not be assumed to cover.

## 9. What is still open

1. **The hook on Instagram is unverified.** That run reported `installed: false`,
   `readyState: complete` — the MAIN script ran after load, so `document_start` never
   happened. The cause is almost certainly 094 § 7.4's trap in a new guise: the permission
   was granted with the tab already open, so Safari injected retroactively. x.com and
   Pinterest both report `installed: true, readyState: loading` on a fresh load. One clean
   tab closes it.
2. **The probe does not scope to the focal post.** On Instagram it picked avatars
   (`s150x150`, `profile_pic`) and a video cover frame; the shipping extractors scope to
   the post. Irrelevant to the auth question, which is about the CDN rather than the size,
   but no byte count above should be quoted as "an Instagram capture".
3. **Reading 2 — persistence.** Unrun, and only needed if the share sheet stays the
   trigger (094 § 2's third candidate). It needs a third process and an App Group.
4. **The trigger.** Untouched by any of this, and now the *only* hard problem left. The
   probe's in-page panel is a working instance of 094 § 2's second candidate and behaves
   exactly as that section feared: it draws over the feed, it is styled against nothing,
   and it would break on a redesign.

## 10. Recommendation

**Tier 3 is a go, and 094 § 8's sizing should be revised down** — the bytes row was priced
as the gate and is now a solved seam that reuses code already written and measured. What
091 called "+4–6 weeks, gated" is no longer gated, and the estimate's one unpriced row is
the trigger, which is where the remaining design effort actually is.

**The per-host control is done, and § 7's design is the rule rather than the common
case** — three platforms, byte-identical, flat 3 MB. Next doc is a plan, not more
research.
