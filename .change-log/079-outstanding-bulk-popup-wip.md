# 079 — Land outstanding bulk/popup WIP (G15)

Lands the previously uncommitted popup + Twitter-scope + bulk-hardening work so
the production-readiness fix phases (docs 020/021) can land as clean, reviewable
commits.

## Summary

- Commits changelogs **073–076** and **078** with their matching source/tests
  (toolbar popup trigger, Twitter bookmark-folder hook + replay buffer, Twitter
  scope filter, bulk review hardening / SSRF media-hosts).
- Includes verification updates in `.docs/019` and the production-readiness
  assessment/plan docs (`.docs/020`, `.docs/021`).
- Ignores a stray raw Twitter bookmark capture at the repo root.

## Files changed

- Extension: popup (`popup.html` / `popup.js` / `popup-view.js`),
  `bulk-context.js`, `bulk-dispatch.js`, `media-hosts.js`, bulk/twitter/sw
  sources + tests, `manifest.json`
- Docs: `.change-log/073`–`076`, `078`; `.docs/019`–`021`
- `.gitignore` — `/twitter-bookmark-folder-response.json`

## Migration notes

None — behaviour already exercised via extension unit tests; no schema change.
