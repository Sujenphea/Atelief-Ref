# 447 — what tier 3 replaces

[096](../.docs/096-tier3-plan.md) said in detail what tier 3 excludes. It never said what
tier 3 **replaces**, and those are different questions with different answers.

§ D4 — "What is out, stated so it is not later" — covers bulk sweeps, RedNote, and the
desktop's `isAllowedMediaHost` gap. All exclusions. Meanwhile § D1 closed with "Tier 3 adds a
better path where the extension is running. **Nothing is removed.**"

Read together, that commits to shipping two capture paths for the same post on the same
phone:

- share a tweet from Safari's share sheet → `PagePreprocessor.js` → **Swift** `PageExtractor`
- capture the same tweet from the extension popup → focal-post → **JS** extractors

Same user, same site, same intent, two implementations, two fidelities. Nobody had decided
which is authoritative, and the sizing table has no row for finding out.

## The decision: tier 3 supersedes tier 2 on the three sites it covers

New **§ D4b**, and a new **T5** to carry it out after T4.

*Why not both.* Tier 3 exists because tier 2 cannot reach current fidelity — that is the
premise of [094](../.docs/094-safari-extension-research.md) and of the whole plan. Two paths
that produce DIFFERENT captures for one post is untriageable: a user shares a tweet twice and
gets two different answers with no way to know which was meant. It is the same objection
`InboxDrain`'s header makes one layer down — "a second runner would mean two things deciding
independently" — applied to extraction rather than to ingest.

*Why tier 2 is not deleted.* It is the only path that works on a site no extractor knows,
and that is most sites. `PageExtractor.web` — og-tags, largest rendered image, canonical URL
— is superseded by nothing, because tier 3's popup only offers itself on hosts the manifest
names. **Tier 2 is the general case; tier 3 is three special cases that happen to be the
three that matter.**

## Why the answer was worth an hour now rather than a discovery in T4

Two things downstream depend on it:

1. **T1 and T2 are ~8 days of work** whose scope reads differently if their output retires
   something. Building them without knowing is building blind.
2. **It settles whether the Swift extractor mirror is scaffolding or infrastructure.**
   [444](444-one-authority-and-a-gate-on-the-mirror.md) put a cross-language gate on the
   URL-rewrite rules a week ago, on the grounds that the mirror had already drifted once and
   nothing was checking it. That gate was right to build and it is **temporary**: the rules
   it pins live in `PageExtractor`'s per-platform branches, so T5 deletes the fixture and both
   readers in the same commit as the branches. A contract left behind to pass vacuously
   against a mirror that no longer exists is worse than no contract, because it looks like
   coverage.

The other cross-language gate, `host-table.js`, survives entirely — it covers host →
platform for `ShareCapture`, which is tier 1 and tier 2 and is untouched.

## Sequencing, stated so it cannot be read as a task

Nothing is removed until T4 has passed on all three platforms on a device. And the decision
is **conditional on T0**: if the focal-post gate fails and tier 3 narrows to post pages only
(§ T0's own stated fallback), D4b narrows with it — tier 3 would supersede tier 2 on post
pages only, and feeds stay tier 2's. Written into D4b rather than left to be rediscovered.

## Files changed

- `.docs/096-tier3-plan.md` — new § D4b; new T5 (~0.5–1 day); sizing total ~3.5–4 →
  **~4–5 weeks**; § D1's "Nothing is removed" struck through and amended rather than edited
  away, since it was the stated position and the change of mind is the information; a third
  revision note in the header.
- `.docs/091-ios-companion-overview.md` — § D5's tier table gains where the three tiers end
  up, so the overview does not keep implying three permanent layers.

Documentation only. No code changed, and none should until T4.

## Migration notes

None. ~4–5 weeks is back inside 091's original "+4–6 weeks, gated" band, and the added
half-week is a deletion rather than a build.
