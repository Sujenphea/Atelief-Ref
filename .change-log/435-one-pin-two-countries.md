# 435 — one pin, two countries

The third and last of the permalink forks, and the only one that is about the host rather
than the path.

## The find

Pinterest serves a country subdomain by geography — `REDACTED`, observed live —
and does **not** redirect it to `www`. Both producers then compose provenance from whatever
host the session happened to be on:

- `pinterest.js` took the live origin through `cleanURL`;
- `bulk-pinterest.js:131` composed `https://${host}${seoUrl}` from the sweep's host.

So one pin can carry two `originalURL`s. The committed fixture is itself an instance of
this: `bulk-pinterest.test.js:30` pins `HOST = "REDACTED"`, and the expected
provenance in that test read `https://REDACTEDREDACTED`.

**Why that forks assets**, verified rather than assumed this time.
`AtelierCore/Tests/AtelierCoreTests/ServicesInvariantTests.swift:77` is titled *"identical
bytes but DIFFERENT provenance → two assets sharing the hash"* and ingests one hash under
two URLs, asserting two assets and one shared blob. 18A dedup keys on bytes **and**
provenance together, exactly as `host-table.js:9` and `InboxDrain.swift:18` describe.
(`IngestInput.swift:37`'s "dedup is by tweet-id" is the separate content/text-card path,
not this one.)

## The fix

`canonicalPinterestHost(host)` in `extractors/base.js`, beside `toOriginals` — whose header
already names it as the place a rule shared by both Pinterest producers lives. Any host
matching `hostIs(host, "pinterest.com")`, including the bare apex and every regional
subdomain, composes as `www.pinterest.com`.

**`pinterest.co.uk` is deliberately left alone.** It is a separate domain, not a subdomain;
`hostIs` is false for it; and asserting it is the same site as `pinterest.com` is a bigger
claim than one observation supports.

**The two jobs `host` does are kept apart.** Only the host that goes into *provenance* is
canonicalized. `buildResourceURL` (`bulk-pinterest.js:191`) still uses the live host, or its
requests would leave the session's region — and a test asserts exactly that pairing rather
than trusting the comment.

## Files changed

- `extension/src/extractors/base.js` — `canonicalPinterestHost`.
- `extension/src/extractors/pinterest.js` — applied to the resolved pin URL.
- `extension/src/bulk-pinterest.js` — applied at line 135, provenance only.
- `extension/test/extractors.test.js` — six cases: regional subdomains and the apex fold,
  `.co.uk` and `pin.it` untouched, a suffix spoof not folded, a regional capture, two
  regions yielding one URL, and a `.co.uk` capture keeping its host.
- `extension/test/bulk-pinterest.test.js` — the fixture's expected `originalURL` updated to
  the canonical host (the assertion **is** the behaviour change), plus two cases: provenance
  canonical while board-feed requests stay regional, and two regions mapping to one URL.

Full suite: 584 pass, 1 skip. `drift-check` clean.

## Migration notes

**A one-time recapture duplicate**, the third in this run
([432](432-the-tweet-with-only-an-analytics-link.md),
[434](434-every-instagram-link-was-a-liked-by-link.md)). Pins already stored under a
regional host keep that `originalURL`; recapturing one now yields the canonical host and
will not dedup against the stored record. Narrower than 434's, since it only bites libraries
built outside the US.

**Weaker evidence than the other two, and worth saying so.** X and Instagram were fixed
against observed sub-page links in a live feed. Here one host was observed and the second
was reasoned about — nobody has seen two regions in one library. It was fixed anyway because
the fix is confined to composing a string at the producer, the dedup rule is untouched, and
a test now pins the invariant either way.

## The set, closed

All three platforms' permalinks are now composed identically by both producers:

| | canonical form | composed by |
|---|---|---|
| x.com | `/{handle}/status/{id}` — no trailing slash | `toStatusPermalink`, matching `bulk-twitter.js:280` |
| instagram.com | `/{p\|reel}/{code}/` — trailing slash | `toPostPermalink`, matching `bulk-instagram.js:179` |
| pinterest.com | `www` host, `/pin/{id}/` path | `canonicalPinterestHost`, both producers |

The differing trailing-slash conventions are intentional: each platform agrees with its own
bulk mapper rather than with a house style, because agreement between the two producers is
what dedup depends on and a house style is not.
