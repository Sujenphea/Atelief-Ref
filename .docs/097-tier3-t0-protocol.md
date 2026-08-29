# 097 — tier 3 T0: how the focal-post session is run (protocol)

> The measurement [096 § T0](096-tier3-plan.md) specifies, written down as a thing to
> execute rather than a thing to re-derive with a phone in one hand. T0 gates D1, and D1
> decides the shape of a **4–5 week** port, so the session is worth ~1.5 days and worth
> not improvising.
>
> **State at the time of writing (2026-08-30): 4 of 90 observations, x.com only, and no
> live page dump at all.** Both gates say so on every test run rather than passing quietly
> — see "What the repo already says about itself" below.

## Why this document exists

The probe answers **six** questions in one session, and five of them are riders: they are
here only because the phone is already in hand and arranging a second device session to
learn them costs more than the questions do. A rider that is forgotten is a rider that
costs a whole extra session, and the failure mode is not exotic — it is reading a hit rate
off the screen thirty times and never once pressing **Dump signals**.

So: one page, six checkboxes, and the exact taps.

## Before you pick up the phone

```bash
# 1. The staging dir is a manifest and a symlink — never copies (404).
ls -la tier3-probe-stage/          # manifest.json -> ../extension/manifest.probe.json
                                   # src          -> ../extension/src

# 2. Regenerate the Xcode project ONLY if the manifest changed:
xcrun safari-web-extension-converter tier3-probe-stage \
  --project-location tier3-probe-xcode --app-name Tier3Probe --no-open --force

# 3. Build + install Tier3Probe to the device, then in iOS Settings:
#    Safari → Extensions → Atelier probe → allow on x.com, instagram.com, pinterest.com.
```

Both staged paths are **symlinks on purpose**: the probe must exercise the shipping
modules, not a copy of them, or the measurement is of the copy. `tier3-probe-stage/` and
`tier3-probe-xcode/` are gitignored — a manifest, a symlink and converter output are not
source.

## The six things, and the tap each one needs

| # | Question | Where it shows | The tap |
|---|---|---|---|
| 1 | **Focal-post hit rate** (the gate on D1) | pick card | tap the post that was **actually** centred |
| 2 | **DOM sufficiency, no hook** (§ D5) | `mediaUrl`, bold when null | read it before tapping |
| 3 | **`executeScript` on an open tab** (§ D8) | status line | note any `executeScript failed:` verbatim |
| 4 | **Instagram works at all** (095 § 9.1) | the whole popup | it either reads or it does not |
| 5 | **Permalink shape** (432 / issue 19A) | `originalURL` | note `/analytics`, `/liked_by/`, `/feedback/` |
| 6 | **A live page dump** (096 review 12B) | signals line | **Dump signals**, once per feed + once per post |

### 1 — the hit rate

**Thirty unplanned popup openings per platform.** *Unplanned* is the whole method: scroll
the way you would actually scroll, stop where you would actually stop, then open the
popup. Choosing a position because it looks decidable is how a 70% rule measures 95%.

Tap the candidate that was genuinely centred. The popup answers `recorded ✓ hit` or
`recorded ✗ MISS` — **that answer is feedback, not the datum.** What is stored is your
tap, so the corpus records what *should* have happened and stays a regression suite after
the rule changes.

**An ad in the centre is a real observation, not a spoiled one.** Tap the `— no link (ad?)`
row: that records "the centred thing was uncapturable", and `null === null` is a hit —
the code and the human agreed there was nothing to take. 437 measured a quarter of the
feed this way.

**Bars, and they are different bars:**
- **live, per platform: ≥27/30**, and misses must be *adjacent* posts, never something
  off-screen. A miss that names a post two screens away is a different defect.
- **forever, in CI: 100% of whatever was captured** — already wired.

**Pinterest is the one to not stop early on.** Its 2-column grid produced winning margins
of **15px and 46px** where x.com produced 274–350 (438). If any platform invalidates D1
it is this one, and it is also the one most likely to be skipped when the session runs
long.

### 2 — does the DOM alone yield media

§ D5 drops the interception hook from tier 3 on the argument that nothing would consume
it. That argument is only as good as this reading: with no hook, `harvestSignals` + the
extractors are the sole provenance source. `mediaUrl` renders **bold when null**, and a
platform that is frequently null sends the hook back into the plan.

Record it per platform as a rate, not an impression.

### 3 — `executeScript` into an already-open tab

The one behaviour that decides whether § D8's reload warning is real. The probe shows the
error **verbatim** rather than mapping it, because the question is what the message *is* —
a missing per-site permission and "nothing here" have to be told apart, and only the raw
string does that. Copy it exactly if it appears.

### 4 — Instagram

095 § 9.1 left it unverified. It is now an ordinary question: does the popup read the
page. No hook is involved.

### 5 — permalink shapes

432 found X handing back `…/status/{id}/analytics` as a post's only link, and normalized
it — 18A dedup keys on `originalURL`, so an un-normalized variant is a duplicate asset.
Instagram (`/p/{code}/liked_by/`) and Pinterest (`/pin/{id}/feedback/`) have the same
shape available and were **reasoned about, never observed**. Read `originalURL` off the
provenance card and note anything with a trailing segment.

### 6 — the live page dump (12B)

**Press Dump signals only when the provenance card reads correctly** for the post you are
looking at. What gets stored beside the raw snapshot is that card — so the expectation is
a human's, exactly as the tap is. Storing the code's own answer unexamined would make the
fixture a snapshot test defending whatever the extractor did that day.

**Two dumps per platform, and the difference is load-bearing:**

- **on a feed** — what tier 3 sees, where the extractors are told which post was centred;
- **on an open post page** — what tier 2 sees, where there is no such context.

`PageExtractor.capture(from:)` on Swift takes **no** `linkUrl`, because a share sheet has
no right-clicked link to pass. So on a feed the two languages are answering different
questions and *must* disagree; only a post page makes a cross-language comparison a drift
check rather than a category error. The probe records `pageKind` so neither test has to
guess. Six dumps total; the signals line reads `x.com·feed, x.com·post, …`.

Video frames are stripped on the way in (they are a JPEG of your screen, Swift cannot read
them, and they dwarf everything else), with `frameStripped` marking the videos that had
one.

## Getting the data off the phone

**Export corpus** → the observations array. **Dump signals** → the whole signals bag.
Both render into the textarea; select all, AirDrop or paste to the Mac.

```
extension/test/fixtures/focal-post-observations.json   ← the corpus (replaces wholesale)
extension/test/fixtures/page-signals-live.json         ← the live pages
```

**Sanitize the signals dump before committing it.** It is a capture of a logged-in feed —
alt text, handles, media URLs — and this repo already has the discipline and the two
scripts, described in `extension/test/fixtures/README.md`:

```bash
node scripts/sanitize-capture.js  ../resources/<raw>.json ../resources/<clean>.json
node scripts/audit-capture.js     ../resources/<raw>.json ../resources/<clean>.json  # LEAKED: 0
```

Read the `structuralSurvivors` list rather than trusting the count. What must survive is
**URL structure** — `pbs.twimg.com/media/…?name=medium`, the `i.pinimg` size segment —
because those shapes are the entire point of the fixture. The observations corpus needs no
sweep: it is geometry plus permalinks, which is what it is measuring.

## What the repo already says about itself

Neither gate is a promise anyone has to remember; both print on every run and convert
themselves the moment the fixtures land.

| Check | Says today |
|---|---|
| `focal-post.test.js` — corpus coverage | `SKIP … x.com 4/30  instagram.com 0/30  pinterest.com 0/30` |
| `focal-post.test.js` — corpus replay | runs against the 4 it has |
| `page-signals.test.js` — coverage | `SKIP … x.com —/—  instagram.com —/—  pinterest.com —/—` |
| `page-signals.test.js` — replay | `SKIP no live page-signal fixture yet` |
| `PageExtractorTests.swift` — `LivePageSignalsTests` | 2 tests skipped, with the reason printed |

Drop the files in and all five become gates with no edit and no remembering.

## If T0 fails

D1 is wrong, and the plan changes shape rather than size. Two ways out, in 096 § T0's
words: revisit candidate 2 (an in-page affordance) with its maintenance cost accepted, or
**narrow tier 3 to post pages only** — where there is no ambiguity to resolve — and leave
feeds on tier 2. The second is the cheaper answer and it invalidates most of T3.

Do not start T1 before this is answered.

## What is still the user's, and blocks nothing here

`sujenphea.AtelierRefsMobileUITests` needs registering as an App ID with the App Groups
capability, joined to `group.sujenphea.AtelierRefs.dev` (Debug) and
`group.sujenphea.AtelierRefs` (Release) — see
[446](../.change-log/446-a-count-is-not-a-tier.md). That gates a signed run of
`Tier2ShareUITests`, not this session.
