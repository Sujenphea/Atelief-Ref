# 467 — the board only ever had covers

## Summary

Planned rednote board sweeping ([098](../.docs/098-rednote-sweep-plan.md)) against
live captures instead of the manual-harvest recollection
[020](../.docs/feature-todo/020-capture-rednote.md) was written from. Four of 020's
load-bearing claims turned out to be wrong, and one of them is a bug that is
degrading captures today.

The board feed is not `POST …/homefeed` but
`GET …/api/sns/web/v1/board/note`, and its rows carry **one cover each** — no
`imageList`, no `video`, no `stream`, zero occurrences of any of them. 020's whole
per-carousel-image fan-out was designed for data the feed does not contain.
Carousels and video need a second, signed, per-note POST.

Hand-signing that POST was tried, using the page's own `window._webmsxyw`, and
rejected: **HTTP 461**, `msg: ""` where every genuine response says `成功`, and a
signer output prefixed `XYW_` where the page sends `XYS_`. So 020's instinct —
never reimplement signing — holds, and `hook-core.js`'s request proxy cannot carry
rednote either: it works for X because a bearer token is URL-independent, and
rednote's signature is URL-bound. Detail expansion, if it happens, has to make the
page issue its own request and listen.

## The live bug

`toRednoteOriginal` takes the last path segment as the CDN object key. For
`oss-sg/spectrum/…` images that drops two segments and builds a 404:

```
http://sns-i27.rednotecdn.com/oss-sg/spectrum/1040g3ug…  → 200  240,729 B jpeg
http://sns-i27.rednotecdn.com/1040g3ug…                  → 404
```

Nothing reports it, because `mediaUrlFallback` catches the 404 and the item saves
as a 47,226 B signed webp. A 5× quality loss with no error and no log.

The replacement rule is the signing prefix, not the tail: the key is the path
minus its first two segments (`<timestamp>/<sighex>/`). Checked over 184 URLs from
both captures, that agrees with the API's own `file_id` **184/184**, where
last-segment disagrees on 36 — and it still works on board covers, where `file_id`
is empty on every row.

## Files changed

- `.docs/098-rednote-sweep-plan.md` (new) — the plan: T0 key fix, T1–T4 cover
  sweep, T5 note-open expansion, T6 video ladder.
- `.change-log/467-the-board-only-ever-had-covers.md` (new)

No code changed yet.

## Migration notes

None. Planning only.

`.docs/feature-todo/020-capture-rednote.md` is now superseded on four points and
should be read through 098's "What the capture overturned" table rather than on
its own. 020's K3 "blocked on a pagination fixture" status is **cleared** — the
terminator is a clean `has_more: false` / `notes: []` / `cursor: ""`, captured.
