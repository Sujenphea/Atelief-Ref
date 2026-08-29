# 432 — the tweet with only an analytics link

A live provenance fork in shipping desktop code, found while validating
[431](431-numbers-in-a-post-out.md)'s selectors against a real x.com feed.

## The find

Running the focal-post reader over a logged-in x.com feed, one of four articles came back
with this permalink:

```
https://x.com/Starlink/status/2077559767858589763/analytics
```

X hangs sub-pages off a tweet — `/photo/1` on the image, `/analytics` on a promoted or own
post, `/history` on an edited one — and `a[href*="/status/"]` matches all of them. The
article carried **no other status link at all**, so no smarter anchor choice could have
rescued it.

`twitter.js`'s `isStatus` accepts it (`pathSegments(u)[1] === "status"` is still true) and
`tweetId` still lands correctly at `segments[2]`. What does not survive is `originalURL` —
and `host-table.js:9` records that 18A dedup keys on provenance.

**This is not tier-3-only.** On the desktop today, right-clicking a tweet's *image* gives
`context.linkUrl` of `…/status/{id}/photo/1`; right-clicking its *text* gives the bare
permalink. Same tweet, two `originalURL`s, two assets off one post. It presents as
duplicates in the library rather than as an error — the class of bug
[404](404-the-mirror-nobody-checked.md) is the changelog of, and the exact failure
096 § T4 is scheduled to go looking for on a device.

The bulk mapper never had it: `bulk-twitter.js:280` *composes*
`https://{host}/{screenName}/status/{tweetId}` from the JSON rather than reading a URL off
the page. So this was the DOM path disagreeing with a producer that was already right.

## The fix

`toStatusPermalink(url)` in `twitter.js` — a status URL reduced to `/{handle}/status/{id}`,
with a non-status URL passed through untouched. Applied **after** candidate resolution
rather than per candidate, so a sub-page URL from any source normalizes: the right-clicked
link, a live `/photo/1` lightbox URL, a stale canonical.

One place, so every caller inherits it — desktop right-click, and tier 3 when it arrives.

## Tests

Nine new cases in `extractors.test.js`: the six sub-page suffixes, idempotence, a canonical
permalink unchanged, non-status URLs untouched, `twitter.com` origin preserved, a truncated
or unparseable URL passed back rather than mangled, the two right-click paths asserted
**equal to each other**, the observed `/analytics`-only promoted post, a live lightbox URL,
and agreement with `bulk-twitter.js:280`'s composed string.

## Files changed

- `extension/src/extractors/twitter.js` — `toStatusPermalink`, exported and applied.
- `extension/test/extractors.test.js` — nine cases.

Full suite: 568 pass, 1 skip (431's corpus placeholder). `drift-check` clean.

## Migration notes

**Behaviour changes for already-captured assets, once.** Anything previously captured via a
`/photo/1` right-click carries the sub-page `originalURL` in the library. Recapturing that
post now produces the canonical permalink, which will **not** dedup against the stored
record — so it lands as one duplicate, once, per affected asset. Accepted deliberately: the
alternative is two producers that normalize differently on the field dedup keys on, which
is the same fork in a more permanent form.

**Not done, and deliberately:** Instagram (`/p/{code}/liked_by/`) and Pinterest
(`/pin/{id}/feedback/`) have the same shape available to them. Neither was observed live —
only reasoned about — and 096 § D4's rule is that a platform gets covered when someone
measures it. Worth a look during T0, when three feeds are already open on a phone.
