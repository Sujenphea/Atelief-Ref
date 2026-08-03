# 324 — rednote is walled (020 · K1)

Pasting a rednote (Xiaohongshu) board or note URL into the app used to resolve
HTTP 200 and silently save a junk item — `og:title` reads `"Web - rednote"` and
`og:image` is a generic 270px share card, because board content is entirely
client-rendered and a cookie-less app-side fetch can never see the real media.
`PageResolver.isAuthWalledHost` now treats `rednote.com` and `xiaohongshu.com`
(both domains serve the same product) the same as `instagram.com` and the
other walled hosts: the app refuses to resolve the link and routes the user to
"Capture with the extension" instead.

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Input/PageResolver.swift` —
  `rednote.com` and `xiaohongshu.com` added to the `walled` host list; the
  doc comment above `isAuthWalledHost` now explains why rednote is walled
  (client-rendered board, generic og: card).
- `AtelierIngestion/Tests/AtelierIngestionTests/PageResolverTests.swift` —
  the walled-host table test gains both new domains (`www.` variant + a deep
  path each) and a suffix-spoof negative, `https://rednote.com.evil.test/a`.

## Test results

`swift test --package-path AtelierIngestion` — **all 259 tests passed**,
including the extended `authWalled` case.

## Migration notes

None — behaviour-only, no schema change.
