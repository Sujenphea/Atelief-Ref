# 430 — the hook nobody would listen to

A review pass over [096](../.docs/096-tier3-plan.md) against the code it plans against.
Sixteen findings, all accepted, folded back into 096 in place. One changes the shape of the
port; the rest are seams the first draft named in prose and left unowned.

## The finding

**096 opened on "the hook ports unmodified" and planned to port a hook nothing would
listen to.**

`hook-core.js` / `twitter-hook.js` emit into exactly one chain, and every link of it is
sweep code: `intercept-source.js:3` → `twitter-source.js:11` → `bulk-twitter.js` →
`bulk-engine.js` / `bulk-controller.js`, with `hook-proxy.js:1` imported by
`bulk-controller.js:26` alone and `twitter-detail-client.js:398` (thread expansion) on the
same footing. Single-item capture never touches any of it — `sw.js:326` injects
`harvestSignals`, shapes it, runs the pure extractors, and resolves video through
`twitter-video.js:16`'s *unauthenticated* syndication endpoint.

096 § D4 drops sweeps. So the manifest it drew injected a MAIN-world hook into three sites
at `document_start` while removing `bulk-loader.js` — the ISOLATED script that would have
been the only listener.

095's headline reading (`fetch=2, xhr=44–61`, GraphQL bodies at one in four) measured a
capability tier 3 does not consume. It stands as a fact about the desktop sweep path. It is
not a fact about this port.

Dropping the hook removed two of 096's five risks, narrowed a third, and shrank the App
Store submission from "wraps `fetch`/`XHR` at `document_start` on three named sites" to
"reads the DOM on a user gesture".

## The other fifteen, by where they landed

**Architecture.** `captureCore` / `ingestOne` fuse the capture decision (video-vs-still,
candidate order, text-card branch) to localhost transport (base64, `127.0.0.1`, token), so
tier 3 needed the first half and could not take the second → a new `capture-plan.js`
(§ D7, T2.5). The native fetch was missing three guards the desktop has — a `Content-Type`
gate (`sw.js:84`), the `mediaUrl → mediaUrlFallback` ladder (`sw.js:250`), and
`isAllowedMediaHost` (`media-hosts.js:30`) → § D6. Dedup equivalence between the two
producers moved from a hand check at the end of T4 to a CI assertion in T2.

**Code quality.** `manifest.json:7`'s `host_permissions` is a fourth copy of the domain
list that `host-table.js` has never checked; 096 proposed a fifth and a manifest↔manifest
set-equality check over it. Replaced with a behavioural arm covering both manifests, in the
form `host-table.js:19` argues for. `sw.js:35-37` imports the bulk tree, so "one JS source
tree" needed `extension/src/safari/` and a module that is not `sw.js`. The popup had no
error vocabulary at all, for a trigger with no badge → `capture-view.js` (§ D8).

**Tests.** T0 made 60 hand-verified observations of real mobile feeds and kept three
numbers, while T3 needed DOM fixtures from nowhere — the corpus is now serialized and
becomes T3's suite, at n=30. `chooseFocalPost` takes numbers, not a DOM, because that is
the split `harvest.js` actually makes (`harvest.test.js:14`). The native message boundary
was called device-bound; `parseNativeMessage` extracts the host-testable part. Nothing
tested a failure travelling *back* to the user.

**Performance.** `InboxWriter.maximumPayloadBytes` (64 MB) was sized against a 120 MB
process and inherited into an 80 MB one → a ~24 MB handler cap. The reused handler's
non-reclaim got a log line and no mitigation, against arithmetic that puts the wall at
~26 captures → `urlCache = nil`, one session per lifetime, an `autoreleasepool`, and a
burst test at N=30 chosen to cross it. And the capture can outlive the popup meant to
report it → fire-and-forget, `queued` on acknowledgement, last outcome on next open.

## Files changed

- `.docs/096-tier3-plan.md` — revised in place. New §§ D5–D8; T0 gains the corpus, the
  n=30 bar and three riders; T1 loses the content scripts and gains the manifest check; T2
  gains `parseNativeMessage`, the equivalence and return-leg tests and the footprint work;
  T2.5 is new; T4 shortens; the risk list is rewritten.
- `.change-log/430-the-hook-nobody-would-listen-to.md` — this file.

No source changed.

## Migration notes

None — planning only. Two things to carry forward when the port starts:

- **095 § 2 should be annotated**, not corrected. Its numbers are right; what changed is
  what they are evidence *for*.
- **§ D6's `Content-Type` check is deliberately post-hoc.** `session.download(from:)`
  returns only after the body lands, and rejecting earlier would mean a
  `URLSessionDataDelegate` rewrite of a measured path to avoid downloading a few KB. It is
  written down in 096 so nobody later reads it as an oversight.

Sizing moved from ~3 weeks to ~3.5–4, still inside 091's "+4–6 weeks". Almost all of the
increase is T2.
