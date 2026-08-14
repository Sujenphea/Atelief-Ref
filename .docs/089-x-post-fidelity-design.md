# 089 — X post fidelity: reposts, quotes, threads (design)

> What an X sweep saves for a post that is not a plain single tweet. Settled with the
> user 2026-08-12; implemented in [384](../.change-log/384-the-whole-post-not-the-fragment.md).
> Extends the fan-out shape from [026](026-tweet-single-capture-plan.md) /
> [030](030-multi-kind-items-overview.md) and the bulk sweep from
> [017](017-bulk-import-design.md).

## The problem

A bookmarks timeline response is not the post. It is the fragment of the post X
happened to serialize into that entry, and three kinds of post lose something real in
the gap:

| Post | What was saved | What was lost |
|---|---|---|
| Repost | the original's media + text | who reposted it |
| Quote | the quoter's text; their media, or the quoted media only if they had none | the quoted tweet's text, always; its media, usually |
| Thread | the one bookmarked tweet | every other tweet in the chain |

## Decisions

**D1 — a repost saves the original, and records the reposter.** Unwrapping to the
original is kept: its media/text/author/permalink are the substance, and unwrapping
is what makes a repost dedup against a direct save of the same tweet. The reposter's
handle goes to `rawMetadata.repostedBy`, written only when present.

*Why not keep the repost's own text:* a plain repost's `full_text` is the
`"RT @user: …"` wrapper. It is not writing, and it reads badly on a card. (A repost
*with* words is a quote tweet, which D2 covers.)

**D2 — a quote saves both halves, under the quoter's permalink.**

- Title = the quoter's words, then `↩ @quotedAuthor: <their text>`. One combined
  string, not a second field: `source.title` is already what the provenance UI and
  all three FTS arms read, so both halves become searchable with no schema change.
  A bare quote (no words of its own) yields the quoted block alone — that IS its
  substance.
- Media = the quoter's own, then the quoted tweet's, sharing the quoter's permalink
  so post-grouping collapses them into one tile with a continuous index.

**D3 — borrowed media are namespaced.** `sourceId` becomes
`<quotingTweetId>:<mediaKey>` for media taken from a quoted tweet.

*Why:* the engine's skip set ([P14]) is keyed on `sourceId`. Reusing the borrowed
`media_key` verbatim means bookmarking both a quote and the tweet it quotes leaves
whichever is swept second with no media at all — a bookmark you made, landing empty,
depending on sweep order. It would also trip `drift.js`, which reads duplicate ids
within a page as evidence X's shape moved. The cost of namespacing is one extra
asset, not one extra file: blobs are content-addressed, so both point at one blob.

**D4 — a thread is one post.** A bookmarked tweet in a self-thread is replaced by the
whole chain — one item per tweet, all sharing the FIRST tweet's permalink, one
continuous `carouselIndex` across the thread. Each tweet keeps `tweetId`; the group
gains `threadId` / `threadIndex`.

*Rejected:* one combined card (all text concatenated). It reads well but collapses
per-tweet media ordering and loses the ability to address a single tweet.

**D5 — the TweetDetail request inherits everything it can.** `features` and the auth
headers come from a timeline request the page just made; only the `queryId` is
scraped, from X's own `api.*.js` bundle.

*Why:* [038](038-grid-bakeoff-results.md)-era discipline recorded in the drift
baseline — "features blob is inherited via MAIN-world interception, never hardcoded".
A features set that disagrees with the server is a 400, not a degraded response, and
`queryId`s rotate every 2–4 weeks. Inheriting is the only thing that survives a client
change; the one value that cannot be inherited is read from the client itself.

**D6 — a features drift repairs itself.** X's 400 names the flags it wanted, so the
request retries with them defaulted true, bounded at `MAX_FEATURE_RETRIES` (2). More
would mask a genuine break.

**D7 — the chain is the reply spine, not the author's tweets.** Walk
`in_reply_to_status_id_str` up to the head and down its continuations (earliest id
wins on a branch).

*Why not filter by author + `conversation_id_str`:* in any popular thread the author
also replies to commenters. Those replies share both the author and the conversation
id, so a filter would file other people's discussion under the thread.

**D8 — expansion always fails soft.** A rotated queryId, a moved bundle, a 429, a
protected conversation, a throw inside the expander — every one degrades to "save the
tweet we already have". Expansion runs on the PULL side of the intercept source, not
in `onResponse`, so it cannot wedge the push path.

**D9 — probe roots, with no toggle** (user, 2026-08-12). A tweet that starts a thread
is indistinguishable from a lone tweet in the timeline, so "save the whole thread"
only holds for the common case — bookmarking the first tweet — if the sweep asks.

*Cost, accepted explicitly:* one `TweetDetail` per bookmarked tweet with any replies.
Tweets with none are screened out for free; each conversation is fetched once per
sweep. Considered and rejected: a popup toggle (adds a decision to a screen that
already has two), and replies-only (free, but misses the case that matters).

**D10 — thread reads are paced independently.** `THREAD_PACING_MS` /
`THREAD_PACING_JITTER_MS`. The engine's item pacing governs relays to the local app;
these go to X's origin, so a page of bookmarks would otherwise fire a burst of
conversation reads — the exact shape the item pacing exists to prevent.

## Security posture

- **Header forwarding is opt-in and allowlisted.** `hook-core.js` reads no headers
  unless a `headerAllowlist` is supplied; X supplies five. `cookie` is not among them.
  `x-client-transaction-id` is deliberately excluded — X derives it per request, and a
  replayed one is worse than none. Values stay in the tab: they are used for
  same-origin requests from the content script and are never relayed to the SW or the
  app.
- **The bundle fetch is host-allowlisted**, https-only, `credentials: "omit"`, and
  separate from the media allowlist because it grants a different thing (script text,
  not image bytes). Same deny-by-default and suffix-spoof safety as
  `isAllowedMediaHost`. The URL is scraped from page-supplied markup and fetched by
  the SW with `host_permissions`, so it gets the same treatment `relay` gives media.

## Open

- `repostedBy` / `threadId` / `threadIndex` are stored but unread by the app UI. A
  detail-view treatment ("reposted by @x", thread position) is unscheduled.
- A thread item's group permalink is the head's; the individual tweet's permalink is
  reconstructible from `tweetId` but not stored as a URL.
- No live verification yet: the whole expansion path is fixture-tested, but the
  `TweetDetail` variables/`fieldToggles` and the bundle path shape are from the
  documented client behaviour, not a captured live response. First live sweep should
  confirm — and, per the drift discipline, a captured TweetDetail body should become a
  committed fixture with its own marker in `drift-baseline.json`.
