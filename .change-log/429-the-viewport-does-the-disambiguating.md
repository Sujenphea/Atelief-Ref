# 429 — the viewport does the disambiguating

[096](../.docs/096-tier3-plan.md) is the plan for the tier-3 Safari Web Extension port.
[095](../.docs/095-tier3-spike-results.md) removed the bytes seam; what was left was the
one thing 094 § 2 said would shape the plan — **the trigger** — and this doc decides it.

## The decision

**The popup, with viewport-centre focal-post selection.**

094 treated "the content script must guess the focal post" as the popup's disqualifying
cost, quoting `sw.js:399`: `info.srcUrl` is "far more reliable than guessing from the page
(esp. capturing a pin from the feed)". That is correct **about a desktop**, where a feed
shows forty candidate images at once and a click is the only way to say which one. A phone
shows one post, sometimes two. The candidate set is an order of magnitude smaller and it is
ordered by something the extension can read: how much of the viewport's centre each post
occupies.

**Candidate 3 — the share sheet as trigger — is not merely costlier, it is worse.** Safari
sends `public.url`, which on a feed is the *feed's* URL: `x.com/home` identifies no post at
all. So it works only once a post page is open, and there candidate 1 has nothing to
disambiguate either. It cannot beat the popup where the popup is weak, and it costs the
always-on accumulator 094 § 2's amendment priced. **Candidate 2 — an in-page affordance —
is dropped for the reason 094 gave, now observed rather than predicted:** the spike's own
panel is a working instance, and it draws over the feed, is styled against nothing, and
would break on a redesign. Three sites, maintained twice.

**Tier 2 is untouched.** The share sheet is shipped and device-proven; it stays the path
for native apps and for Safari without the extension. Tier 3 adds a better path where the
extension runs.

## The gate that could still say this is wrong

The guess is unproven, so T0 measures it before anything is ported: focal-post selection
added to the throwaway probe, ~20 unplanned scroll positions per platform, **bar set at
≥18/20 with near-miss failures only** — named in advance rather than after the numbers are
in. If it fails, the fallback is stated: narrow tier 3 to post pages, where there is no
ambiguity, and let feeds stay tier 2.

## One source tree, two manifests

`extension/src/` does not get forked. The Safari target references the same files and adds
`extension/manifest.safari.json`, which differs only in dropping `http://127.0.0.1/*`
(nothing listens), dropping `bulk-loader.js` (sweeps are out), and swapping the background
worker and popup.

This is [404](404-the-mirror-nobody-checked.md)'s rule applied again: the drift gate exists
because a domain added to the JS extractors and not to `ShareCapture.swift` ships as forked
provenance. A second JS copy would need a third arm on that check. The manifests get a
drift check of their own instead — every host in one is in the other or on a named
exception list.

## Sizing

~3 weeks (T0 1 day · target 3–4 · native seam 3–4 · trigger 4–5 · end-to-end 3–4), against
091's "+4–6 weeks, gated". The difference is almost entirely 095: the bytes seam was priced
as an unknown with a spike in front of it and is a `URLSession.downloadTask` into code that
already exists.

## Files

Documentation only.

- `.docs/096-tier3-plan.md` — new. D1–D4, T0–T4, sizing, gates.
- `.docs/095-tier3-spike-results.md`, `.docs/094-safari-extension-research.md` — pointed at
  096; 094 § 2's trigger question marked decided there.

## Migration notes

None — no code changed.

Two risks recorded that are not obvious from the code. **Per-site permission granted to an
already-open tab injects retroactively**, so `document_start` never happens and the
extension appears to do nothing until reload — it bit the spike twice, and it will bite
users, so the popup has to say so. And **App Store review of an extension that reads page
traffic on three named sites** is a different conversation from a share extension; worth
knowing before T1 rather than after T4.
