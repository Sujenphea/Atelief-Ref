# 428 — three CDNs, none of them asked

[427](427-the-wall-was-on-the-post-not-the-picture.md) established on X that a session-less
`URLSession` fetches the same media bytes the logged-in page gets, and left one thing
open: whether that generalises. [095 § 8.1](../.docs/095-tier3-spike-results.md) asked for
the control per host before a plan committed to "the native side fetches" as a rule.

**It generalises.** Instagram and Pinterest, same day, same probe:

| host | with session | no session | native footprint |
|---|---|---|---|
| x.com | 200 · 125,523 B | **200 · 125,523 B** | 2.9 MB |
| instagram | 200 · 52,422 B | **200 · 52,422 B** | 3.0 MB |
| pinterest | 200 · 116,340 B | **200 · 116,340 B** | 3.1 MB |

Byte-identical on every one, and the native footprint is **flat at 2.9–3.1 MB** across
platforms and payload sizes — it is a file copy, and file copies do not scale. 095 § 7's
design is the rule, not the common case.

## Two things worth keeping

**Instagram signs its media URLs and it changes nothing.** The signature is on the URL, not
on the cookie jar, so a session-less fetch presenting the same signed URL gets the same
bytes. It also closes the URL-lifetime question 095 raised: `oe=6A92F98C` decodes to
**2026-08-29T15:23Z — about 99 hours out**. "The native side fetches later" is not a race at
any timescale a capture lives on.

**Pinterest 403'd first, and the control is what proved it was not an auth wall.**
`/originals/` returned `403 · 263 B · application/xml` *identically with and without the
session* — a CDN that does not look at credentials, answering about a pin whose original
Pinterest had not kept. `extractors/pinterest.js:37` already says so ("`/originals/` can
404 … the rendered size is kept as a fetch fallback"); the probe had rewritten to
`/originals/` with no fallback, which the shipping extractor would never do.

The fix is the finding: the probe now transcribes each platform's **fallback chain** from
the extractors (`twitter.js:55`, `pinterest.js:37`) instead of inventing a rewrite, and
both readings walk it, recording every attempt. A probe without those chains reads a
missing file as a dead platform — which is very nearly what happened.

RedNote was not run and stays known-walled ([324](324-rednote-is-walled.md)). It is the one
host 095 § 7 should not be assumed to cover.

## Files

Documentation only.

- `.docs/095-tier3-spike-results.md` — § 8 becomes the per-host results; the old § 8.1 and
  § 8.2 (per-host, URL lifetime) are answered and gone; § 9 is now what remains open, and
  it is two items, both about the probe rather than the platform.

## Migration notes

None — no code changed.

**Two items remain open, and neither blocks a plan.** The hook is unverified on Instagram
(that run injected retroactively — permission granted with the tab already open, so
`readyState` was `complete` and `document_start` never happened; x.com and Pinterest both
read `loading` on a clean load). And the probe does not scope to the focal post, so it
picked avatars and a video cover frame on Instagram — irrelevant to a question about the
CDN, but no byte count above should be quoted as "an Instagram capture".

**The trigger** (094 § 2) is now the only hard problem left in tier 3.
