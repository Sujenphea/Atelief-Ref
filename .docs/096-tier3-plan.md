# 096 — tier 3: the Safari Web Extension port (plan)

> The build order for the port [094](094-safari-extension-research.md) researched and
> [095](095-tier3-spike-results.md) measured. Planned against the tree on
> `feat/ios-companion` (2026-08-25), with every seam either measured on a device or
> already shipping on the Mac.
>
> **091 priced this at "+4–6 weeks, gated". It is no longer gated, and the estimate comes
> down** — the row that was priced as the gate turned out to reuse code that already
> exists and is already measured. What is left is one design decision and a port.

## What 095 settled, so this plan does not re-argue it

- **The hook ports unmodified.** `hook-core.js` copied verbatim, MAIN world at
  `document_start`, `readyState: loading` on every clean load.
- **No fidelity ceiling.** `fetch=2, xhr=44–61` — the mobile site prefers XHR, nothing
  hides in a worker, and the hook wraps both.
- **Bytes are not a problem.** All three live CDNs serve identical bytes to a session-less
  `URLSession`. The native side fetches to a file at a **flat 2.9–3.1 MB**, and the ~120
  lines that do it are already written (`ShareViewController.fetchMedia`).
- **The chain is one hop longer than 094 drew it** — native messaging lives in the
  background worker, not the content script.
- **The handler's ceiling is 80 MB**, not the share extension's 120.

## The one decision this plan has to make

**The trigger.** 094 § 2 called it the seam that would shape the plan, and it is the only
part of tier 3 that is design rather than porting. Three candidates were on the table.

### D1 — The popup, with viewport-centre focal-post selection

**Because the phone's viewport does most of the disambiguation the right-click was doing.**

`sw.js:399` says `info.srcUrl` is "far more reliable than guessing from the page (esp.
capturing a pin from the feed)", and it is right *about a desktop*: a desktop feed shows
forty candidate images at once, so a click is the only way to say which. **A phone shows
one post, sometimes two.** The candidate set the guess has to resolve is smaller by an
order of magnitude, and it is ordered by something the extension can read — how much of the
viewport centre each post occupies.

094 treated "the content script must guess the focal post" as the popup's disqualifying
cost. On this form factor it is a much cheaper guess, and D2 below gates it with a
measurement rather than an assumption.

**Candidate 3 (share sheet as trigger) is not just costlier — it is worse.** Safari's share
sheet sends `public.url`, which on a feed is the *feed's* URL: `x.com/home` identifies no
post at all. So candidate 3 works only once the user has opened an individual post — and at
that point candidate 1 has no ambiguity to resolve either. It cannot beat the popup where
the popup is weak, and it costs an always-on accumulator pushing intercepted payloads to
native while the user browses (094 § 2, amended). Dropped.

**Candidate 2 (in-page affordance) is dropped for the reason 094 gave, now observed.** The
spike's own panel is a working instance of it: it draws over the feed, it is styled against
nothing, and it would break on a redesign. Three sites' redesigns, maintained twice. The
desktop extension has deliberately never done this and this is not the moment to start.

**Tier 2 stays exactly as it is.** The share sheet is shipped, tested and device-proven; it
remains the capture path for native apps and for Safari when the extension is not enabled.
Tier 3 adds a better path where the extension is running. Nothing is removed.

### D2 — The focal-post guess is gated by measurement, before anything is ported

If the guess is wrong often enough to be annoying, D1 is wrong and the plan changes shape.
That is a one-day answer and it comes first — see T0.

### D3 — One JS source tree, two manifests

`extension/src/` stays the single copy. The Safari target references those files; it does
**not** get a fork.

The reason is the gate that already exists: `npm run drift-check` (`ci.yml:109`) compares
`extractors/` and `media-hosts.js` against `ShareCapture.swift`, because a domain added on
one side and not the other ships as forked provenance
([404](../.change-log/404-the-mirror-nobody-checked.md)). A second JS copy would need a
third arm on that check, and the whole point of 404 was that unchecked mirrors drift.

What differs is the manifest, and only the manifest:

| | Chrome | Safari/iOS |
|---|---|---|
| `host_permissions` | includes `http://127.0.0.1/*` | **dropped** — nothing listens (094 § 3) |
| `bulk-loader.js` content script | present | **dropped** — sweeps are out (094 § 6) |
| `background` | `sw.js` (module) | a small worker that forwards to native |
| `action.default_popup` | the sweep controls | the capture trigger |

### D4 — What is out, stated so it is not "later"

**Bulk sweeps.** 2,407 lines of `bulk-*.js`, excluded per 094 § 6: a sweep is a desk
activity, it runs for minutes against a non-persistent worker, and half the codebase not
ported is half the codebase not maintained twice.

**RedNote.** Known walled ([324](../.change-log/324-rednote-is-walled.md)) and not covered
by 095 § 7's design. It can be added when someone measures it.

---

## T0 — the focal-post gate (before any port)

**Why first:** D1 is the only unproven thing in the plan, and it is unproven in a way that
changes the shape rather than the size. Answer it on the throwaway probe, which already
runs on all three platforms and already has a popup.

**Do:** add a `focalPost()` to the probe — the `article` (or platform equivalent) whose
bounding box covers the most of the viewport's vertical centre — and have the popup report
the post id and its media URL. Scroll a feed, open the popup at ~20 unplanned positions per
platform, and record whether the chosen post is the one visibly centred.

**Verify:** a hit rate, per platform, written into 095 as a results section. The bar is
worth naming in advance rather than after: **≥18/20 on each platform**, and the misses have
to be near-misses (an adjacent post) rather than something off-screen.

**If it fails:** D1 is wrong. Revisit candidate 2 with the maintenance cost accepted, or
narrow tier 3 to post pages only — where there is no ambiguity — and let feeds stay tier 2.

**~1 day.** No target, no provisioning.

## T1 — the Safari Web Extension target

**Do:** a fifth target in `AtelierRefs.xcodeproj`, hand-written rather than converter-
generated — [400](../.change-log/400-the-pen-changed-hands.md) established that Xcode's
target sheets fight this project, and 094 § 1 records the converter emitting a bundle
identifier that cannot build. The converter's output is a reference, not the source of
truth.

The target's Resources reference `extension/src/` per D3, plus a Safari `manifest.json`
that lives beside them (`extension/manifest.safari.json`) so the two manifests are diffable
against each other.

**Verify:** it builds; the extension appears in Safari's settings on a simulator; the hook
reports `installed: true, readyState: loading` on x.com. Add the manifest pair to
`drift-check`: **every host in one manifest is in the other, or is on a named exception
list.** That check is three lines and it is the reason a domain never gets added to one and
not the other.

**~3–4 days**, mostly project file and permissions paperwork.

## T2 — the native seam

**Do:** `SafariWebExtensionHandler` receives a `CaptureRequest`-shaped JSON plus a media
URL, runs it through `AtelierCapture.CaptureDecoder` — the same funnel the share extension
and the Mac endpoint both use — fetches the URL with `URLSession.downloadTask`, and writes
through `InboxWriter`. Everything downstream already exists and is measured.

**Don't** put bytes in the message. 095 § 5 is the record of why, including the number
(2.36× payload, 80 MB ceiling, killed at 32 MB).

**Do** carry the 80 MB figure into the code the way 423 did: log `bytes=` and `footprint=`
on every capture, so a regression that pulls decoding back into the handler shows up in a
log line rather than in a profiler. And note 095 § 5's side effect — **the handler process
is reused between messages and does not reclaim promptly**, so a burst of captures
accumulates. At ~3 MB each that is fine; the log line is what will say if it stops being.

**Verify:** the decode and write halves are `AtelierCapture` and test on the host under
`swift test`. What needs the device is the message boundary itself, and it is one
round trip.

**~3–4 days.**

## T3 — the trigger

**Do:** the popup, T0's focal-post selection promoted out of the probe and into
`extension/src/` as a tested pure function (a DOM fixture in, a post id out —
`node --test`, the way `harvest.js` splits page-reading from deciding), and the extractors
run against the chosen post to build provenance.

**Verify:** the pure half under `node --test` with captured DOM fixtures per platform; the
popup by hand on a device.

**~4–5 days.**

## T4 — end to end, per platform

**Do:** capture from a feed and from a post page, on x.com, instagram.com and
pinterest.com, and confirm the record reaches `inbox/`, drains on the Mac, and dedups
against the same post captured by the desktop extension — which is the real proof that the
two producers still speak one contract.

**Verify:** the dedup. If a tier-3 phone capture and a desktop capture of the same post
produce two assets rather than one, the provenance forked, and that is the failure 092 · S0
exists to prevent.

**~3–4 days**, device-bound.

---

## Sizing

| | |
|---|---:|
| T0 — focal-post gate | ~1 day |
| T1 — the target | 3–4 days |
| T2 — the native seam | 3–4 days |
| T3 — the trigger | 4–5 days |
| T4 — end to end, three platforms | 3–4 days |
| **total** | **~3 weeks** |

Against 091's "+4–6 weeks, gated". The difference is almost entirely 095: the bytes seam
was priced as an unknown with a spike in front of it, and it is a `URLSession.downloadTask`
into code that already exists.

## Gates and risks

1. **T0's hit rate.** The only gate that can change the plan's shape. It is first for that
   reason.
2. **Per-site permission before page load.** 094 § 7.4, and it bit the spike twice — once
   on `twitter.com` vs `x.com`, once on Instagram, where granting permission to an
   already-open tab injected retroactively and `document_start` never happened. **This is
   a user-facing problem, not just a test problem:** a user who enables the extension while
   sitting on a feed will see it do nothing until they reload. The popup should say so.
3. **App Store review.** An extension that reads page traffic on three named sites is a
   different review conversation from a share extension. Not a technical risk and not this
   plan's to solve, but it should be known before T1 rather than after T4.
4. **The hook on Instagram is still unverified** (095 § 9.1) — one clean tab load, and it
   should happen during T0 rather than being discovered in T4.
5. **Video is easier here, not harder.** The desktop extension rasterizes a frame because a
   video post has no still on the server; under 095 § 7 the native side downloads the video
   variant to a file at the same flat cost as an image. The constraint that shaped the
   desktop design does not apply.

## Start here

T0. It is a day, it runs on a probe that already exists, and it is the only thing in this
plan that could still say the design is wrong.
