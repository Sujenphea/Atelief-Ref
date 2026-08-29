# 433 — a probe that reads the real modules

The measurement instrument [096](../.docs/096-tier3-plan.md) § T0 needs, plus the
diagnostic that makes its failures legible.

## Summary

094's amendment records that the last tier-3 probe lived in a session scratchpad and is
gone. This is its replacement, and it differs in one way that matters: **it imports the
shipping modules rather than a copy**, so a reading taken on a phone is a reading of what
will ship.

That forced a structural choice. An extension resolves module imports against its root, so
a sibling `extension/probe/` root could not reach `../src/safari/focal-post.js` without
copying it — and an unchecked mirror is the failure
[404](404-the-mirror-nobody-checked.md) exists to prevent. So the probe PAGE lives inside
`src/`, and only the manifest is a sibling: `extension/manifest.probe.json`, beside the
shipping `manifest.json`, which is the same arrangement 096 § D3 plans for the Safari one.

**One screen answers five questions**, because they all need the same phone and the same
tap:

1. the focal-post hit rate — the reading, the pick, and a human's verdict on which post was
   actually centred;
2. **DOM sufficiency without the hook** (096 § D5) — the provenance panel's `mediaUrl`,
   flagged when null, since that is the reading that would send the hook back into the plan;
3. **the permalink shape per platform** (096 § T0's fourth rider) — the panel's
   `originalURL`, so Instagram's `/p/{code}/liked_by/` and Pinterest's `/pin/{id}/feedback/`
   are observed rather than reasoned about, which is what
   [432](432-the-tweet-with-only-an-analytics-link.md) deliberately deferred;
4. **whether the page yields geometry at all** — see below;
5. **what a missing per-site permission actually looks like** (096 § "Gates and risks" 3) —
   the `executeScript` failure is shown verbatim rather than mapped, because the probe's job
   is to find out what the message *is*.

Recording goes to `storage.local` and comes back out through a textarea, because a phone
has nowhere to write a file to. The stored shape is the corpus format 431 fixed:
`{ reading, expectedPostUrl }[]`. `expectedPostUrl` is the HUMAN's answer, so the corpus
records what should have happened rather than a snapshot of today's behaviour — which is
what makes it a regression suite.

## `no-geometry`, and why it is not `none-visible`

While validating 431's selectors against live feeds, both instagram.com and pinterest.com
returned candidates whose every rect measured **zero pixels tall** — the selector matched,
the permalinks were there, the geometry was not. Cause unresolved (virtualization,
`content-visibility`, or a feed that had not laid out).

Left alone, that reaches `chooseFocalPost` as candidates scoring zero everywhere and comes
back as `none-visible` — the same answer as a user who has genuinely scrolled every post off
screen. Two different failures wanting two different fixes, arriving as one shrug.

So the reading now carries `zeroRectCount` beside `linklessCount` (the same instinct: a
count that separates "the selector matched nothing" from "it matched things that were no
use"), and `chooseFocalPost` returns `reason: "no-geometry"` when **every** candidate is
zero-height. A MIXTURE stays `none-visible` — some geometry existed, it just was not in
view. The probe flags both counts in bold, because the point of being on a phone is that
noticing is expensive.

## Files changed

- `extension/src/safari/focal-post.js` — `zeroRectCount` in the reading; the `no-geometry`
  reason.
- `extension/test/focal-post.test.js` — two cases: all-zero → `no-geometry`, mixture →
  `none-visible`.
- `extension/src/probe.html`, `extension/src/probe.js` — new. The instrument.
- `extension/manifest.probe.json` — new. Root is `extension/`; no content scripts (096 § D5),
  no `127.0.0.1`.
- `.docs/096-tier3-plan.md` — T0 gains the permalink rider (three riders → four) and names
  where the probe lives.

Full suite: 570 pass, 1 skip (the corpus placeholder). `drift-check` clean.

## Migration notes

**The probe is throwaway and says so in its own header.** When T0 is answered, delete
`src/probe.html`, `src/probe.js` and `manifest.probe.json`. The modules they exercise stay,
because 431 wrote them as the shipping ones.

**Loading it.** The manifest's root is `extension/`, which suits the Xcode target (it
references resources explicitly). Chrome's "load unpacked" wants a file literally named
`manifest.json`, so desktop loading means temporarily using `manifest.probe.json` under that
name — a manifest swap, never a module copy.

**Still unanswered, and not by this:** nothing here has been run on a phone, and the mobile
DOM remains unconfirmed — `resize_window` was a no-op in the desk validation, so every
selector observation so far is desktop layout. Pinterest's grid attributes are the least
certain of the three.
