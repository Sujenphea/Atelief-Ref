# 072 — X timeline hook also intercepts XMLHttpRequest (the real transport)

After [071](./071-twitter-hook-classic-script.md) made the hook install, T9 *still*
enumerated zero. Live diagnosis on x.com/i/bookmarks: the hook was confirmed installed
(`window.__atelierTimelineHookInstalled === true`, `window.fetch` was our wrapper), a
`Bookmarks` request fired on scroll and the URL predicate matched it — yet nothing was
captured. An XHR probe (`XMLHttpRequest.prototype.open`) caught it immediately.

## Root cause

**X's live web client pulls the timeline over `XMLHttpRequest`, not `window.fetch`.**
The hook wrapped only `fetch`, so the paginated `Bookmarks` XHRs sailed past it and the
push→pull source drained to `complete` with zero counts.

## Fix

`installTimelineHook` now wraps **both** transports (`twitter-hook.js`):
- **fetch** (unchanged) — kept for robustness / other call sites.
- **XHR** (new) — `XMLHttpRequest.prototype.open` stamps the URL on the instance;
  `send` adds a passive `load` listener that, for a timeline URL, reads the body
  (`responseText` for text, `response` for `responseType: "json"`) and `post`s the
  parsed JSON. Fully guarded — it never touches the page's own handlers or the response,
  and a parse failure is swallowed. Idempotent via the shared `scope` flag; installs if
  *either* transport exists.

## Tests (`bulk-twitter.test.js`, +3 → node --test 183 pass)

- A timeline XHR forwards its parsed body; a non-timeline XHR (HomeTimeline) is ignored.
- `responseType: "json"` reads the pre-parsed `response`.
- An unparseable XHR body is swallowed — `send()` never throws into the page.

## Verified

`node --test` **183 pass**. Root cause confirmed live (XHR probe caught the exact
`Bookmarks` request the fetch hook missed). Requires an **extension reload**. T9 live
re-run pending — the sweep should now enumerate bookmarked media.
