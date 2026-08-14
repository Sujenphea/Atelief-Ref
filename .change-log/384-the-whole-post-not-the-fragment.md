# 384 — the whole post, not the fragment

An X sweep used to save the piece of a post that happened to be in the timeline
response. A repost lost the reposter. A quote kept the quoter's words and threw the
quoted tweet's away, borrowing its picture only when the quoter had none. A thread
arrived one tweet at a time and stayed that way.

Three changes, all so that what lands in the library is the thing you bookmarked.

## Reposts keep the reposter

A repost still unwraps to the original — its media, text, author and permalink are
the substance, and unwrapping is what makes a repost dedup against a direct save.
What was missing is that unwrapping threw away the only thing a repost adds. A plain
repost has no words of its own (`legacy.full_text` is the `"RT @user: …"` wrapper,
which is why it isn't kept as text); the reposter's handle IS the addition. It now
rides `rawMetadata.repostedBy`, written only when there is one, so an ordinary
tweet's stored metadata is byte-for-byte what it was.

## Quotes carry both halves

A quote is half a thought without the thing it quotes.

- **Text** — the title is the quoter's words, then the quoted byline and text below
  (`↩ @author: …`). One combined string rather than a second field, so both halves
  land in the one place the app's provenance UI and FTS already read, with no schema
  change.
- **Media** — the quoter's own, then the quoted tweet's, all under the QUOTER's
  permalink (what was bookmarked), so the two sets group into one tile the way a
  carousel does. Previously the quoted media were a fallback used only when the
  quoter had none.

Borrowed media are namespaced `<quotingTweetId>:<mediaKey>`. The engine's skip set is
keyed on `sourceId`, so a borrowed `media_key` reused verbatim would collide with a
direct save of the quoted tweet and silently strand whichever was swept second — and
it would trip the drift check, which reads duplicate ids within a page as evidence X
changed its response shape. Namespaced, both bookmarks save in full; the app is
content-addressed, so that is two assets over one blob.

## Threads expand

A bookmarked tweet belonging to a self-thread is replaced by the whole chain: each
tweet its own item, all sharing the FIRST tweet's permalink, with one continuous
`carouselIndex` so the tile opens in reading order rather than restarting at zero on
each tweet. Each tweet keeps its own `tweetId` and gains `threadId` / `threadIndex`.

The rest of a thread isn't in the bookmarks response — it takes a `TweetDetail` call,
and nothing about that request is hardcoded:

- the `features` blob and the auth headers are **inherited** from a timeline request
  the page itself just made (the MAIN-world hook now forwards an allowlisted set of
  request headers alongside the response — they never leave the tab);
- only the `queryId` can't be inherited, so it is scraped from X's own `api.*.js`
  bundle. A content script can't fetch `abs.twimg.com` under the page's CORS, so the
  SW fetches it under `host_permissions`, behind a new https-only host allowlist.

A features drift repairs itself: X answers a missing flag with a 400 that names the
flags it wanted, so the request retries with them on, bounded at two rounds.

The chain is rebuilt by walking `in_reply_to_status_id_str` up to the head and down
its continuations — deliberately not by filtering on author + conversation id, which
would also sweep in the author's replies to other people's comments.

Every failure degrades to "save the one tweet we already have": a rotated queryId, a
moved bundle, a 429, a protected conversation, a page whose expansion throws.

**Cost.** A tweet that STARTS a thread is indistinguishable from a lone tweet in the
timeline, so the sweep probes — one `TweetDetail` per bookmarked tweet with any
replies. Tweets with none are screened out for free and each conversation is fetched
once per sweep. These are a second request stream the engine's item pacing doesn't
cover (it paces relays to the local app; these go to X), so they carry their own
paced, jittered gap.

## Files changed

- `extension/src/bulk-twitter.js` — `repostedBy`; `combineQuoteText` / `tweetText`;
  `collectMedia` with borrowed-media namespacing; both media sets merged; items carry
  a local `threadHint`.
- `extension/src/twitter-thread.js` — **new.** queryId scraping, request building,
  the features-drift repair, the reply-chain walk, `mapThread`, `createThreadExpander`.
- `extension/src/hook-core.js` — opt-in `headerAllowlist`; forwards request headers on
  both the fetch and XHR paths; `open()` clears a reused XHR's stash.
- `extension/src/twitter-hook.js` — declares the five forwarded header names.
- `extension/src/intercept-source.js` — optional async `expandItems`, applied on the
  PULL side; a throw degrades to the unexpanded page.
- `extension/src/twitter-source.js` — passes `expandItems` through.
- `extension/src/bulk-controller.js` — harvests `features` + headers off the hook
  messages, builds the expander, routes the bundle fetch through the SW.
- `extension/src/bulk-sw.js`, `bulk-messages.js`, `media-hosts.js` — the
  `BULK.bundle` route and its `isAllowedBundleHost` allowlist.
- `extension/src/config.js` — `THREAD_PACING_MS` / `THREAD_PACING_JITTER_MS`.
- `extension/README.md` — the above, plus a correction: it claimed bulk sweeps save
  the actual video unconditionally. Video has been opt-in (`resolveVideo`, default
  off) and the doc had not caught up.
- Tests: `twitter-thread.test.js` (new, 35), plus header-forwarding cases in
  `hook-core.test.js` and updates to `bulk-twitter.test.js` / `drift.test.js` for the
  rules that changed. 462 pass.

## Migration notes

None — no schema change, nothing stored differently for existing items.

Two swept-shape changes to be aware of on the next sweep:

- A quote tweet now yields MORE assets than before (its own media plus the quoted
  tweet's). Previously-swept quotes are not backfilled; a re-sweep picks up the
  borrowed media as new items under their namespaced ids.
- The drift check's X `mediaItems` signal moved 5 → 8 on the committed fixture. That
  is the merge rule, not drift.

`rawMetadata.repostedBy` / `threadId` / `threadIndex` are stored but not yet surfaced
anywhere in the app UI — the data is there for a detail-view treatment to read.
