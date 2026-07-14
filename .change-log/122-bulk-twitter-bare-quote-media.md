# 122 — Bulk sweep captures a bare quote tweet's quoted media

Fixes: a bookmarked **quote tweet** whose media lives in the QUOTED tweet (a "repost
of a video" in the user's words) swept in with no video. Diagnosed live: the tweet
had `ownMedia: []` and the video sat in `quoted_status_result` — and the mapper
deliberately excludes quoted media (it's normally the quoted author's asset). So a
bare quote of a video → a text card, video dropped.

## What ships

- **`bulk-twitter.js` `quotedTweet(tweet)`** — resolves the embedded quoted tweet
  (`quoted_status_result.result`, unwrapped).
- **`mapTweet` media fallback** — media source is the tweet's OWN media, or — when it
  has NONE — the QUOTED tweet's media. So a bare quote of a video/image captures it
  (poster card + `videoUrl` for the opt-in download), keyed by the bookmarked (quote)
  tweet's own id/text/author. A quote that HAS its own media is unchanged (own wins;
  the quoted media is NOT merged).

## Why this (not the earlier retweet unwrap)

The live capture showed **0 reposts, 4 quotes** — the user's "reposts" are quote
tweets, so fix 121 (retweet `retweeted_status_result` unwrap) didn't apply. This is the
actual fix. Retweet unwrap (121) still stands for real retweets and composes with this.

## Files changed

- `src/bulk-twitter.js` (`quotedTweet` + `mapTweet` media fallback; header note).
- `test/bulk-twitter.test.js` (bare quote → quoted video; quote-with-own-media wins;
  a genuine text-only tweet; the fixture's 3rd tweet is itself a bare quote of a video).
- `test/drift.test.js` (`mediaItems` 4 → 5: the bare-quote tweet now contributes its
  quoted video).

## Tests

Extension **298** green (`node --test`). Drift CLI passes (`tweetCount=3 mediaItems=5`).
No Swift change.

## Notes

- Identity: the item keeps the BOOKMARKED quote tweet's id/text/author; only the media
  is borrowed from the quoted tweet. So it dedups as the quote you saved and opens to
  it (which shows the quoted video).
- Video still needs the sweep's "Download full video" opt-in to store the MP4; without
  it the quote lands with the quoted video's poster as its card.
