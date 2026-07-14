# 121 — Bulk sweep saves a repost's original media (bug fix)

Fixes: a bookmarked/liked **repost (retweet)** swept in with no media. A retweet's
own `legacy.full_text` is only `"RT @user…"` and it carries NO media — the substance
(text + media) lives on `legacy.retweeted_status_result.result`. `mapTweet` read only
the top-level tweet's media, so a repost mapped to an empty text item and its picture
was lost.

## What ships

- **`bulk-twitter.js` `underlyingTweet(tweet)`** — resolves a repost to the ORIGINAL
  tweet it carries (via `retweeted_status_result.result`, unwrapped), or the tweet
  itself otherwise. `mapTweet` now reads media / text / author / id from it, so a
  reposted tweet saves the **original's** media and is keyed by the **original's**
  tweet-id — which also means a repost and a direct save of the same tweet dedup
  together.
- A **quote** tweet is deliberately NOT unwrapped: its own text is the substance and
  the quoted media belongs to the quoted author (unchanged rule).

## Files changed

- `src/bulk-twitter.js` (`underlyingTweet` + `mapTweet` reads from it; header note).
- `test/bulk-twitter.test.js` (+1: a repost → the original's media/author/id).

## Tests

Extension **296** green (`node --test`, +1). No Swift change. The committed X fixtures
contain no retweet (only quotes), so the test builds a synthetic repost; existing
tests are unaffected (`underlyingTweet` is identity for a non-repost).
