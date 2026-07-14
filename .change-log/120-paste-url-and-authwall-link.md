# 120 — Plain-text URL paste + auth-walled hosts save a bare link

Two link-capture UX fixes surfaced while testing C2b (changelog 118).

## 1. Pasting a URL as plain text now works

`CollectionView.firstWebURL` only recognized a pasted URL that arrived as an NSURL
object or the `public.url` pasteboard type — so a URL copied as TEXT (the address bar,
a message, a doc) carried only `public.utf8-plain-text` and fell through to
"couldn't read that drop." Now the grid paste path also parses the plain-text string,
via a new pure `IngestionModel.webURL(fromPastedText:)` guarded by a **dotted-host**
check so arbitrary text (`hello`, `just a note`) isn't turned into `https://hello`.

## 2. Auth-walled hosts save a bare link (not nothing)

Pasting / adding an `x.com` (or instagram / pinterest) URL previously showed a small
"use the extension" status and saved NOTHING — which read as "nothing happened".
`resolveLinkAndIngest` now saves a **bare link** for an auth-walled host: it still
does NOT fetch the page (so no login / garbage share-card, no SSRF), but the paste
yields a clickable link item keyed by the URL. The extension remains the way to get a
rich tweet with its card image. Reuses the tested `linkInput(page: nil)` bare-link path.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` (`webURL(fromPastedText:)`; auth-walled
  branch → bare link).
- `AtelierRefs/AtelierRefs/CollectionView.swift` (`firstWebURL` plain-text branch).
- `AtelierRefs/AtelierRefsTests/LinkResolutionTests.swift` (+1: `pastedTextGuard`).

## Tests

AtelierRefsTests green (`xcodebuild`). No Swift package / schema change.

## Behavior after both fixes

- Paste/add a public page URL → resolved link (title + og:image card).
- Paste/add an `x.com` etc. URL → a bare link item (no fetch); use the extension for
  the full tweet.
- Paste a non-URL word / sentence → ignored (dotted-host guard), as before.
