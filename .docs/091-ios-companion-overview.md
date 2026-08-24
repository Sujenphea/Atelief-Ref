# 091 — iOS companion: share-sheet capture on a phone (overview)

> Answers "what would it take to have this on iOS, where I share into it from the
> share sheet?" Grounded in a reconnaissance pass over the five packages, the app
> target and the extension as they stand on `feat/x-post-fidelity` (2026-08-13) —
> every LOC figure and file citation below was measured, not estimated.
>
> The conclusion is a **companion, not a port**: the answer to "how hard is the iOS
> app" and the answer to "how hard is share-to-save on a phone" differ by roughly a
> factor of five, and only the second one is the actual ask.

## What the port surface actually is

Measured over `Sources/` and the app target, excluding tests and `.build/`:

| Module | LOC | AppKit files | Verdict |
|---|---:|---:|---|
| `AtelierCore` | 9,043 | 0 | **Free.** GRDB is iOS-native; `platforms:` line only. |
| `AtelierExport` | 1,576 | 0 | **Free.** CoreGraphics/CoreText, zero product deps by design (052 · 3A). |
| `AtelierIngestion` | 7,347 | 1 | **Near-free.** The one file is `Input/DirectInputReader.swift` (NSPasteboard / NSItemProvider). |
| `CanvasRenderer` | 6,204 | 5 | **Split.** `Host/` is 4,112 of those lines — the CALayer host + text-edit controller need a UIKit twin. The pure ~2.1k (transform, culler, LOD, shaping) ports as-is. |
| `AtelierServer` | 1,435 | 0 | **Deleted.** A loopback endpoint for a desktop browser extension has no meaning on iOS. |
| `AtelierRefs` (app) | 46,054 | 52 of ~130 | **Rewritten.** See below. |

So ~18k lines — Core, Export, Ingestion, and the pure half of CanvasRenderer — move
for approximately the cost of changing `.macOS("26.0")`. That is a direct return on
the package-boundary discipline from 001/003; it is unusual, and it is what makes a
companion cheap enough to be worth doing.

The 46k-line app target is the port. Not because of API mismatches — because it is a
**macOS interaction model**. `MasonryGridHost.swift` (2,113 lines, 147 NS-symbols) is
an `NSCollectionView` bridge that exists because it won a measured bake-off
([037](037-grid-bakeoff-protocol.md)–[039](039-grid-bakeoff-gate-results.md)); on iOS
that decision is re-opened, not translated. `SidebarOutlineKit` / `CollectionsOutlineView`
/ `SpacesOutlineView` are NSOutlineView. `KeyMap.swift` is 620 lines of keyboard map
([077](077-keyboard-map-plan.md)) with no iPhone analogue. Marquee-select
(`GridMarquee`), hover (`HoverButtonStyle`), right-click (`GridContextMenu`, NSMenu),
and drag-with-modifiers ([048](048-drag-unification-plan.md)) are four interaction
primitives that do not exist on touch — Spaces in particular is a direct-manipulation
canvas designed around a cursor and a modifier key.

## Decisions

### D1 — Build a companion, not a port

v1 is: **share sheet in, inbox, sync to the Mac library, read-only browse.** No
Spaces, no canvas, no moodboard/contact-sheet export, no bulk sweeps, no archive
round-trip. Every AppKit-heavy file in the table above is out of scope by
construction, and the reused surface is exactly the ~18k that ports free.

*Why not the full app:* the canvas and Spaces are the two places where the
interaction model has to be re-derived rather than re-implemented, and they are also
the two places least useful on a phone. A companion is not a subset chosen to save
time; it is the part of the product that a phone is actually good at — capture
happens where you are, curation happens at a desk.

### D2 — The share extension writes an inbox record; it does not ingest

A share extension is a separate process on a much tighter memory budget than the host
app (observed ceilings around 120 MB, and not a contractual number). `IngestPipeline`
decodes originals and generates the thumbnail tiers — a 4000px share would put the
extension into jetsam, and the failure mode is a share sheet that silently does
nothing.

So the extension does the smallest durable thing: writes the payload plus a
`SourceDraft`-shaped provenance sidecar into an App Group **inbox** directory, and
returns. The host app drains the inbox on next foreground (and via
`BGProcessingTask`), running the *existing* `IngestCoordinator` unchanged.

This also keeps the writer story honest: one process opens the `DatabasePool`
(`LibraryDatabase.swift:41`), and the extension never touches SQLite at all. WAL
would technically survive two writers, but "the extension only appends files to a
directory" is a boundary that cannot be got wrong later.

### D3 — The library root moves to an App Group container

`LibraryLocation.defaultRoot()` resolves `<Application Support>/ref-atelier/`
(`LibraryLocation.swift:20`). On iOS the app and its extension share nothing at that
path; the root must come from
`containerURL(forSecurityApplicationGroupIdentifier:)`.

The change is small and additive — a platform-conditional base directory behind the
same function — and the `-library-root` / `ATELIER_LIBRARY_ROOT` override
(`LibraryLocation.swift:55`) must keep working for tests, so the override branch is
untouched. **Gate:** set the data-protection class on the library root explicitly
(`completeUntilFirstUserAuthentication`) rather than inheriting a default, or a
background drain on a locked device fails to open the database.

### D4 — Sync is one-way (iOS → Mac) in v1, over the archive manifest

There is no server, and inventing one for a single-user companion is the wrong first
move. But the round-trip contract already exists: `LibraryArchive.swift` defines a
manifest whose whole design point is **import idempotency** — provenance is copied
verbatim precisely so `AppServices.ingest`'s 18A blob-hash dedup reuses an existing
asset instead of forking a second one over the same bytes
(`LibraryArchive.swift`, rule 1).

An iOS capture set is therefore expressible as a small archive, and importing it on
the Mac is a solved path ([068](068-backup-portability-plan.md) · H7). v1 ships that:
the phone accumulates, the Mac absorbs, duplicates collapse by construction.

*Why not CloudKit now:* two-way sync means conflict resolution over collections,
ordering, and Spaces geometry — a design problem the size of this whole document.
One-way merge has no conflicts to resolve. If the companion earns two-way, that gets
its own research doc.

### D5 — Fidelity on iOS is a different capture, and the doc should say so plainly

The extension's fidelity comes from hooking `fetch`/XHR in the MAIN world at
`document_start` and harvesting GraphQL bodies (`hook-core.js`, `twitter-hook.js`,
[089](089-x-post-fidelity-design.md)/[090](090-x-post-fidelity-review-plan.md)). Three
tiers are available on iOS, and they are not equivalent:

| Path | What it yields |
|---|---|
| Share from a **native app** (X, Instagram) | a URL, nothing else → `PageResolver` og-tags: title, description, one image. Cookie-less by design (`PageResolver.swift:10`), so a login-walled post yields a bare card. |
| Share from **Safari** | a URL **plus DOM**, via `NSExtensionJavaScriptPreprocessingFile` — an action/share extension may run JS in the shared page and return a dictionary. DOM scraping works; the extractors in `src/extractors/` are largely reusable. Interception does **not** — the page has already loaded, so there is no `document_start` to hook. |
| **Safari Web Extension** on iOS | the real port of `extension/`, content scripts and all — the only path that can reach current fidelity. |

v1 takes tier 1 + tier 2 and states the limit in the UI rather than pretending. Tier 3
is the follow-on, gated on the open question below.

*Correcting the first read:* an iOS share is not URL-only. Safari's JS preprocessing
gives real DOM access, which is a meaningful step above og-tags — it just cannot see
the network traffic that `twitter-hook.js` exists to read.

### D6 — No in-app logged-in browser

A `WKWebView` the user logs into would restore interception and near-parity. It is
also a new product surface, an App Store review risk, and a ToS question. Not in v1,
and not without a decision recorded separately.

## Sizing

| Slice | Estimate |
|---|---:|
| App Group container + data protection + `LibraryLocation` seam | 3–5 days |
| Share extension (inbox write, both tiers of D5), host-side drain, BG task | 1.5–2 weeks |
| Minimal SwiftUI browse (grid + item detail, read-only, no NSCollectionView) | 2–3 weeks |
| Archive-based one-way sync (phone side + Mac import wiring) | 1–1.5 weeks |
| **v1 companion total** | **5–7 weeks** |
| Safari Web Extension port for fidelity parity | +4–6 weeks, gated |
| Feature-comparable iOS app (Spaces, canvas, exports, search) | 3–5 months |

## Open questions

1. ~~**Does Safari on iOS support `world: "MAIN"` content scripts at `document_start`?**~~
   **Answered on a device (2026-08-25): YES, on iOS 26**
   ([425](../.change-log/425-the-main-world-is-open-on-ios.md)). A probe extension
   injected at `readyState: loading`, intercepted 36 of the page's own XHRs on a
   logged-in x.com including a GraphQL call, and its ISOLATED control could NOT see the
   MAIN world's globals — so `world` was honoured rather than silently ignored. **Tier 3
   is unblocked**; the hook can be ported. Note that
   `xcrun safari-web-extension-converter` WARNS that `world` is unsupported, and is
   wrong — which is why this was verified functionally rather than from the tooling.
2. **Which collection does a share land in?** The Mac app always has a selected
   collection; a share sheet has no context. Options: a fixed *Inbox* collection, a
   last-used default, or a picker in the extension UI (costs the extension a
   read-only view of the collection tree, which conflicts with D2's "no SQLite in the
   extension"). Leaning: fixed Inbox, sorted later on the Mac.
3. **Does the phone need the analysis stack?** Vision / NaturalLanguage /
   `PerceptualHash` all exist on iOS and would port, but running them on-device costs
   battery for derived data the Mac recomputes anyway. Leaning: skip on iOS, let the
   Mac analyze on import.
4. **Deployment target.** The packages pin `.macOS("26.0")` on the reasoning that
   nothing older ever runs them; the iOS floor should be audited from the APIs
   actually used rather than assumed.

## Follow-on docs

- [092-ios-companion-plan](092-ios-companion-plan.md) — the build order, S0–S6.
  The separately-planned `design` doc was folded into it: the two contracts that
  needed designing (the shared capture DTO, the inbox record) are each half a page
  and belong beside the slice that builds them.
- A Safari-extension research doc, only after open question 1 is answered.

**Settled since this doc was written.** Open question 2 (which collection a share
lands in) is answered in 092 · S3: `Collection.unsortedID`, the same default the
capture endpoint already uses — no new Inbox-collection concept, and nothing about
the collection tree crosses the process boundary.
