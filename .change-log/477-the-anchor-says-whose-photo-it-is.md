# 477 — the anchor says whose photo it is

[099 · P11](../.docs/099-mac-backlog-plan.md) is the extension's one TODO, and it had
been sitting in `twitter.js` since changelog 124 reverted the first attempt at it:

> *(A rare quoted-tweet photo inside the focal article can leak in; excluding it needs a
> per-photo status-id signal — a separate change, TODO — not the overbroad `role="link"`
> heuristic that dropped the tweet's OWN photos.)*

A quote renders **inside** the quoter's `<article>` and has no `<article>` of its own, so
`articleIndex === 0` — the scoping that keeps a reply's image out — keeps the quoted photo
in. `payload.media[]` then carries an image that belongs to somebody else's post under the
quoter's permalink.

It is excluded now. Each of a tweet's own photos is wrapped in
`<a href="/{handle}/status/{id}/photo/{n}">`, so the anchor states which status the photo
belongs to; the harvest reads it, and the X extractor keeps a focal-article photo only
when that id is the focal tweet's.

## The plan said the signal was already in the DOM. It was — and it was nowhere near the extractor

099 · P11 reads *"the per-photo status id the TODO asks for is already in the DOM.
`mediaMatching` keeps a photo only when its anchor's status id equals the focal
`tweetId`"*, which describes a one-line filter in one file. That is not what was there.

`mediaMatching` filters `harvest.media` on `m.src`, and a harvested media item is
`{ kind, src, width, height, alt, articleIndex }`. No href, no anchor, nothing about an
enclosing element at all — `harvestSignals` reads five properties off each `<img>` and the
index of its containing `<article>`, and that is the entire set of facts the extractors
have ever been given. The signal is in the page's DOM; it had never been harvested, so
there was nothing for a filter to filter on.

So the phase is three files rather than one, and it lands the shape
[026](../.docs/026-tweet-single-capture-plan.md) · 5A specified for this exclusion in the
first place — *"tag quoted media in `harvestSignals` … and filter it out"*:

- **`harvestSignals` reads the anchor.** `statusIdOf(el)` takes `el.closest('a[href*="/status/"]')`,
  reads the **attribute** (X writes these relative), and walks the segments for the one
  after `status`. Absolute hrefs parse identically, and `?`/`#` are cut first.
- **`buildHarvest` carries it.** The `withArticle` helper — which existed to carry
  `articleIndex` through only when the reader supplied it — becomes `withScope` and carries
  both. An absent key still means "no signal", which is what every consumer already assumed.
- **`twitter.js` uses it.** `belongsToStatus(media, tweetId)`, exported and tested on its
  own, and one `ownPhotos` list that the card and `payload.media[]` are both derived from,
  so a photo cannot be rejected from one and kept in the other.

## The fixture the phase was pointed at is the wrong artifact — and the shape is real anyway

The brief said to verify the `/status/{id}/photo/{n}` shape against
`test/fixtures/x-conversation.js` before relying on it. That file cannot answer the
question: it is a **synthetic TweetDetail JSON builder** (`tweet()`, `photo()`,
`conversation()`) shared by `twitter-thread.test.js`, `twitter-detail-client.test.js`,
`twitter-thread-integration.test.js` and `drift.test.js`. It emits
`media_url_https` inside a GraphQL envelope. It has no anchors, no hrefs, and no way to
become a harvest — the DOM extractor's tests do not import it and could not use it.

The shape is committed elsewhere, twice, and both are better evidence than a synthetic
builder would have been:

- **`x-thread-detail.json`** — a live, sanitized TweetDetail capture — carries eighteen
  `expanded_url`s of the form `https://x.com/{handle}/status/{id}/photo/1`, at
  `legacy.entities.media[]` and `legacy.extended_entities.media[]`. That is X stating its
  own per-photo URL for a status, from a real response.
- **`toStatusPermalink`'s own doc comment**, which exists *because* of this anchor:
  *"right-click a tweet's IMAGE and you captured `…/status/{id}/photo/1`"*. A context
  menu's `linkUrl` is the enclosing `<a href>`, so that sentence is a live observation of
  the exact anchor this phase reads, recorded in this file two changes ago — and it is
  already a committed test: *"twitter: a right-clicked PHOTO link yields the post
  permalink, not /photo/1"* passes `linkUrl:
  "https://x.com/designer/status/1780000000000000000/photo/1"` and says in its own comment
  *"right-clicking the image gives linkUrl=/photo/1"*. The photo anchor is not a guess;
  the suite has been asserting against its href for two changelogs.

## The rule is one-sided, and that is the decision the phase turns on

`belongsToStatus` drops a photo **only when it positively names a different status**. No
`statusId` and no focal `tweetId` both mean keep.

That is not defensive coding, it is choosing a failure direction. 124 was reverted because
its heuristic matched a tweet's own clickable photos and dropped them — the capture came
back with nothing, and nothing looks like a bug in the app rather than in a selector. With
the rule one-sided, the worst a stale or broken selector can do is stop excluding, which
returns the extension to exactly the state this TODO described. A photo that goes missing
is a silent failure; a quoted photo that leaks is the one we have lived with for two
changelogs and can see.

It also means the phone is UNCHANGED by construction — not fixed, unchanged.
`AtelierRefsShare/PagePreprocessor.js` reads no anchors, so its snapshots carry no
`statusId`, every photo in them keeps, and an iOS capture behaves exactly as it did
yesterday. That is the correct outcome for a phase that may not touch that file, and it is
listed below as a gap rather than sold as a property.

## One behaviour changed on purpose

A quote tweet whose quoter added **no photo of their own** used to capture the quoted
tweet's image; it now captures as a text card. The card is the head of the same list, so
this follows from the exclusion rather than being a second decision — and it is the same
rule the extractor already applies one level up, where a text-only focal tweet stays
image-less rather than borrowing X's generic `og:image`. An image whose provenance would
be the quoter's permalink is not that post's image.

## The tests assert what survives, not only what goes

Six new cases (638 tests, up from 632; 635 pass, 3 skipped, 0 fail):

| Test | File |
|---|---|
| `belongsToStatus: drops only a photo that names a DIFFERENT status` | `extractors.test.js` |
| `twitter: a quoted tweet's photo is excluded, the tweet's OWN photos kept` | `extractors.test.js` |
| `twitter: a quote tweet with no photo of its own → a text card, not the quoted image` | `extractors.test.js` |
| `twitter: a harvest with no status ids keeps every focal photo` | `extractors.test.js` |
| `twitter: a right-clicked quoted photo is still honored — an explicit choice wins` | `extractors.test.js` |
| `statusId: carried through when the reader provides it, omitted otherwise` | `harvest.test.js` |

A test that only asserted the exclusion would pass for a rule that drops everything, which
is the exact bug 124 shipped. So the paired case asserts the whole surviving list in DOM
order (`[OWN1, OWN2]`, quoted photo removed from the middle) and that the card is the
tweet's own. **Checked by mutation** rather than by intent: forcing `belongsToStatus` to
`return true` (the rule does nothing) fails 3 tests, and forcing it to `return false` (the
rule drops everything) fails 12. Both directions are held.

## The selector is on the live-verify list, because no fixture can hold it

026 · 9A: *"Quoted DOM detection stays E2E-only (consistent with the no-jsdom decision) …
add the selector to the drift-check manual checklist."* The pure halves are tested; the
`closest('a[href*="/status/"]')` read is a live-DOM fact and this suite has no jsdom by
decision. So `drift-check.js`'s **"Drift markers to re-verify live"** block — which already
names the focal-`<article>` scoping the same way — gains the photo anchor, with the way to
check it (right-click a quoted photo, read the `linkUrl`), and `test/fixtures/README.md`'s
marker list gains the long form and the evidence.

## The gate

`node --test` clean at 638. `npm run drift-check` **exits 2**, which is staleness, not
drift: the Instagram fixture aged out of its 14-day window on 2026-08-28, before this
branch existed, and only a fresh capture from a logged-in session clears it. The canary
prints *"No drift — every check that COULD run satisfied its invariants"* and every check
that ran is `✔`. [464](464-the-gate-tells-its-two-arms-apart.md) split the two arms for
precisely this reading, and `verify.sh` renders the stage as `⚠ Extension`.

**`verify.sh full` did NOT reach exit 0 on this machine, and the diff is not the cause.**
Run 1, verbatim:

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target (Release)
  ⚠ Extension
  ✗ App target

1 stage(s) failed.
```

Run 2, the re-run, verbatim:

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ AtelierExport
  ✓ App target (Release)
  ⚠ Extension
  ✗ CanvasRenderer
  ✗ App target

2 stage(s) failed.
```

**Every red is a clock, and the machine was running three phases at once.** This phase
shared the Mac with two sibling agents building Swift, and `uptime` read **load 16.85 /
24.62 / 23.96 on 8 cores** while the app stage ran, with a foreign `xcodebuild` and a
`swift-frontend` at 601 % CPU alongside it. What failed says the same thing:

- `CanvasRenderer` (run 2 only) failed **two frame-budget assertions** and nothing else —
  `CanvasBenchmark.testFrameUpdateWithinBudget` measured 9.38 ms against an 8.33 ms
  120 fps budget, `testGlyphTextWithinBudgetAcrossZooms` 8.85 ms against the same. Re-run
  alone it passes: **437 tests, 52 suites, exit 0**.
- `App target` failed a **different set each run**, and every member of every set is a
  bounded wait. Run 1: one test, `SwitcherRankingTests.onlyTheTitleIsMatched`, at exactly
  **60.000 s** — the runner's hang timeout — after which the test host relaunched with a
  new pid. Runs 2 and 3: thirteen cases, all `LibrarySearchModelTests` (~25 s each),
  `PollTests.settlesEarly` and `CollectionReadModelTests.ingestBurstCollapses` (60.000 s).
  `poll(timeout:)` — 099 · 11A's shared helper — defaults to **3 seconds**, and
  `ingestBurstCollapses` waits on the coalescer's 500 ms window. Those are the tests that
  fail first when eight cores are asked to do the work of twenty-four.
- The stage that CANNOT be a clock passed every time: `App target (Release)`, a full
  compile, is `✓` on both runs. So the app builds; it does not finish waiting.

The structural argument is the stronger one. **This diff contains no Swift, no
`project.pbxproj`, and no file the Xcode project references** — six files under
`extension/` plus this changelog and 099. `extension/` is not a target: P17 is the phase
that would make it one and it has not run. Nothing in `AtelierRefsTests` or
`CanvasRendererTests` can observe a change to `harvest.js`. The App-target stage was
re-run once on its own, as the brief directs, and failed the same way; it was not chased
further, because a third full run on a machine at 3× its core count is contention, not
verification.

The two stages this phase can actually be judged by are green and deterministic:
`node --test` **638 tests, 0 failures**, and `⚠ Extension` from a drift check reporting
**no drift**.

## What is still NOT covered

- **The selector itself has not been run against x.com.** Every pure half is tested and
  the URL shape is evidenced twice, but *"a tweet's photo is inside that anchor and a
  quoted tweet's photo is not inside the quoter's"* is a claim about a live page that no
  test in this repo can make. It is on the drift-check list for a person to check, and the
  one-sided rule is what makes being wrong survivable rather than a regression.
- **A quoted tweet whose photo carries no anchor still leaks.** If X renders the quoted
  card without wrapping its image in a permalink, `statusId` is null, the rule keeps it,
  and the TODO's symptom persists — quietly. That is the price of the one-sided rule and
  it is deliberate; the same live check settles it.
- **The phone still leaks it.** `AtelierRefsShare/PagePreprocessor.js` is the iOS twin of
  `harvestSignals` and reads no anchors, so an iOS share-sheet capture of a quote tweet
  behaves as it did before this change. It is outside `extension/` and outside this
  phase's remit. `ios-preprocessor.test.js`'s "both readers agree" comparison does not
  catch this: it compares `src`, dimensions and `articleIndex` field by field, so a field
  present in one reader and absent in the other is a **seventh divergence its allowlist
  does not mechanically detect**. Naming it here rather than pinning it, because pinning
  it means editing a file this phase may not touch.
- **Video is untouched.** `statusId` is read for `<img>` only. A quoted tweet's *video*
  poster is not excluded, and neither is anything reached through `firstMediaOfKind`.
  Rare enough that no observation of it exists; if one turns up, the field and the
  helper are already the right shape for it.
- **The bulk path was already correct and is unchanged.** `mapTweet` reads top-level
  entities out of the timeline JSON, so it never had this problem;
  [089](../.docs/089-x-post-fidelity-design.md)'s quote-merge design, which deliberately
  DOES take quoted media under a composite key, is a separate producer and is not touched
  here.
- **099's other P11 line is not done.** The plan's gate section assigns this phase a
  second item — *"a fixture with every `items` array emptied passes the Instagram check,
  since it reports counts as signals without asserting they are non-zero. The other checks
  were not probed for the same hole."* This commit is the TODO only. The hole is real,
  it is unrelated to anything above, and probing the other five checks for it is its own
  small phase with its own tests.
