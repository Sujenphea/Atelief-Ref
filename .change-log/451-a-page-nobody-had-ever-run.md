# 451 — a page nobody had ever run

096 review **12B** was the last of the sixteen findings and the only one left open, because
it needs a phone. Half of it does. The half that does not is the half that has to exist
*before* the phone is in hand, and that is what this is.

## The gap

`PageExtractorTests.swift` and `extractors.test.js` both run on **hand-composed** harvests:
an object with three metas and two images, trimmed to exercise one rule. That is the right
shape, and it is deliberately kept — a composed fixture says *which* rule broke where a
page snapshot says only "something changed".

What neither can say is whether the rule still fires on a page X served today. A live feed
is 100+ images — avatars, card art, tracking pixels — in an order nobody composing a
fixture would think to write down, and `largestMedia`, the article-index scoping and the
`name=orig` rewrite are all decisions taken against exactly that. `fixtures/README.md`
already states the defect, about Instagram's composed fixture carrying 11–13 keys per media
where the live API sends 108–128:

> Running the canary over it proved only that our own reduction still parsed.

Two extractors, two languages, and **neither had ever been handed a real page.**

## Dump signals

A third button on the probe. It stores the raw `harvestSignals` snapshot for the current
page, keyed by page URL, alongside the provenance **currently on screen**.

**The expectation is the human's, exactly as it is for a tap.** The operator reads the
provenance card — platform, author, `originalURL`, `mediaUrl` — and presses the button only
when it is right for the post being looked at. Recording the code's own answer unexamined
would make this a snapshot test that defends whatever the extractor did on the day, bugs
included. Read off the screen first, it is the same evidence the focal-post tap is.

**Frames are stripped**, and `frameStripped` marks the videos that had one. Three reasons
and only the third is size: a rasterized frame is a JPEG of whatever was on the user's
screen and this file gets committed; Swift's `RawPageSignals.Video` has no `frame` field at
all, so it could never be replayed there; and it dwarfs everything else in the snapshot. A
fixture whose two replays read different media lists is worse than one that carries
neither — but a page silently presented as frameless is worse again, hence the flag.

## `pageKind`, which is the finding

The dump is keyed by page URL rather than host, and carries `pageKind: "feed" | "post"`.
That is not tidiness. It came out of writing the Swift replay and finding it could not work:

**`PageExtractor.capture(from:)` takes no context.** It dispatches on the page's own URL,
because tier 2 is a share sheet and a share sheet has no right-clicked link to pass. The JS
extractors *do* take a `linkUrl` — on a feed, tier 3 tells them which of forty posts was
centred.

So on a feed dump the two languages are answering different questions and **must**
disagree: Swift would report `x.com/home`, which is not a post at all. Asserting agreement
there would report drift where none exists, which is the fastest way to teach someone to
ignore a gate. Post pages are where the two converge.

Hence **two dumps per platform**, and hence keying by page URL — keyed by host, the feed
dump and the post dump would have silently overwritten each other.

## Both replays, written now, skipping loudly

- `extension/test/page-signals.test.js` — replays **every** entry through `buildHarvest` +
  `extractProvenance`; the `linkUrl` is real on this side. Plus a coverage test whose bar
  is a feed *and* a post per platform.
- `PageExtractorTests.swift` · `LivePageSignalsTests` — replays the **post pages only**,
  through `PageHarvest.build(from:)` + `PageExtractor.capture(from:)`, and says in its
  header why the feeds are excluded. A second test decodes every entry either way, because
  a feed dump the Swift decoder cannot read is a surprise waiting for someone later.

This is `drift-check.js`'s mirror guard ([404](404-the-mirror-nobody-checked.md)) applied to
page **shape** instead of host tables.

All four skip with a sentence rather than passing quietly, on the pattern
`focal-post.test.js` established, and convert to gates the moment the file lands — no edit,
no remembering.

**Verified they bite**, not merely that they run: a synthetic fixture was dropped in, both
suites went green, one expected field was perturbed, and both failed naming the host, the
field, the wanted value and the got. Then it was removed.

## 097, so the session is executed rather than re-derived

The probe now answers **six** questions and five of them are riders — there only because
the phone is already in hand. A forgotten rider costs a whole extra device session, and the
realistic failure is reading a hit rate thirty times and never once pressing Dump signals.
`.docs/097-tier3-t0-protocol.md` is one page: the staging commands, the six questions with
the tap each needs, both bars, the sanitize step before committing a logged-in capture, and
a table of what every gate says about itself today.

## The staged manifest was a copy

`tier3-probe-stage/` symlinks `src → ../extension/src` precisely so the probe measures the
shipping modules. Its `manifest.json` was a **copy** — identical today, unchecked forever,
and the one file that changes whenever the probe needs a new permission. Now a symlink too.

## Files changed

- `extension/src/probe.js` — `SIGNALS_KEY`, `storedSignals`, `refreshSignals`,
  `stripFrames`, `pageKindOf`, `dumpSignals`; raw signals + provenance held in `state`.
- `extension/src/probe.html` — the button and the signals line.
- `extension/test/page-signals.test.js` — new, 2 tests.
- `AtelierCapture/Tests/…/PageExtractorTests.swift` — `LivePageSignalsTests`, 2 tests.
- `.docs/097-tier3-t0-protocol.md` — new.
- `.docs/096-tier3-plan.md` — § T0 points at 097; rider 5 added (four → five).
- `tier3-probe-stage/manifest.json` — copy → symlink (gitignored).

## Verification

`npm test` → **618** tests, 615 pass, **3** skipped (the corpus coverage gate, and the two
new ones), 0 fail — from a baseline of 616/615/1. `npm run drift-check` → no drift.
`swift test` in AtelierCapture → **117** tests in 8 suites, 2 of them the new skips.

*(The baseline is 616/615/1. A previous summary reported it as 617/616/1.)*

## Migration notes

None. Nothing ships in the extension or the app; the probe is a measurement instrument that
is deleted when T0 is answered, and the four new tests are inert until the fixture exists.

**Still the phone's half:** capture the dumps, sanitize, commit. 12B closes then.
